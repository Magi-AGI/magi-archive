# frozen_string_literal: true

# R3 dev preservation: keeps the dev-only Administrator docs, nav and the named dev accounts across the refresh.
#
#   R3_PRESERVE_STEP=capture  on the CURRENT dev database, in a read-only session. A dry run reports counts and writes
#                             nothing. Only with R3_CAPTURE_WRITE=1, set by r3/run_ruby.sh behind --apply and R3_GO, does
#                             it write a mode-600 JSON file on the host. That file holds card content and account emails,
#                             so it stays on the host, is never copied out, and is deleted after the restore. It holds no
#                             password, salt or token.
#   R3_PRESERVE_STEP=restore  on the STAGED database. Recreates through the app layer, so every card gets a FRESH id, and
#                             writes an old-id => new-id reference map. No id is ever written or reused.
#
# Accounts get a random password nobody knows; the person resets it. There is no password preservation and no hash export.
# Restore is a dry run unless R3_RESTORE_APPLY=1, which r3/run_ruby.sh sets only behind --apply and R3_GO. A dry run does
# all the work in a transaction and rolls it back. It never commits, so it never reaches Decko's integrate phase and
# cannot prove that phase.
# An apply commits card by card, because Decko runs each card's integrate phase from after_commit, and that raises under
# an outer transaction. A run that stops halfway therefore leaves a partial staged copy. The reference map exists before the
# first commit and is saved as each card lands, including a card whose integrate phase raised after its commit. To recover,
# drop the staged copy, restore it from the dump again, and delete the map file.
# Before the first create, the card id sequence moves past every captured id and the occupied range, so no card can take
# one. A dry run puts that sequence back; its rolled-back creates still leave gaps in the act and action id sequences.
# Prints ids, counts and classes, never content or emails.
#
# Env: R3_PRESERVE_FILE, R3_MAP_FILE, R3_DEV_ACCOUNTS (comma-separated names), R3_DEV_NAV_CARDS (optional, comma-separated).
require "json"
require "securerandom"
require "digest"

STEP = ENV["R3_PRESERVE_STEP"].to_s
FILE = ENV["R3_PRESERVE_FILE"].to_s
ROOT = "Administrator"
# Occupied by retained production GM cards on dev; a card created here must never land on one of them.
OCCUPIED_IDS = (10_986..11_013).freeze

def bot(&block) = Card::Auth.as_bot(&block)
def stop(message)
  warn "REFUSED: #{message}"
  $stdout.flush
  exit!(2)
end
stop("R3_PRESERVE_FILE is not set") if FILE.empty?

def assert_staged!
  db = ActiveRecord::Base.connection.current_database
  stop("restore runs only on a database named *_staged") unless db.end_with?("_staged")
  # Read after the app loaded its env file, which can set it again. R3 requires a dormant mirror, so this stops, not unsets.
  stop("the mirror gate is set in the app env; R3 needs a dormant mirror, remove it first") if ENV["ATOMSPACE_MIRRORING_ENABLED"].to_s.casecmp?("true")
  puts "database: #{db}"
end

def card_entry(card)
  { "old_id" => card.id, "name" => card.name.to_s, "type" => card.type_name.to_s, "content" => card.db_content.to_s }
end

def ancestry_ids(root_id)
  ActiveRecord::Base.connection.select_values(<<~SQL).map(&:to_i)
    WITH RECURSIVE tree AS (
      SELECT id FROM cards WHERE left_id = #{root_id.to_i} AND NOT trash
      UNION ALL
      SELECT c.id FROM cards c JOIN tree t ON c.left_id = t.id WHERE NOT c.trash
    ) SELECT id FROM tree
  SQL
end

CREDENTIAL_CODENAMES = %w[account password salt api_key token email status].freeze

def credential_part?(card)
  [card.left_id, card.right_id].compact.any? { |i| CREDENTIAL_CODENAMES.include?(Card.where(id: i).pick(:codename).to_s) }
end

def capture
  accounts = ENV.fetch("R3_DEV_ACCOUNTS", "").split(",").map(&:strip).reject(&:empty?)
  stop("name the dev accounts to preserve in R3_DEV_ACCOUNTS") if accounts.empty?
  nav = ENV.fetch("R3_DEV_NAV_CARDS", "").split(",").map(&:strip).reject(&:empty?)
  conn = ActiveRecord::Base.connection
  stop("capture reads the current dev database, not a staged copy") if conn.current_database.end_with?("_staged")
  conn.execute("SET SESSION default_transaction_read_only = on")
  bundle = { "docs" => [], "nav" => [], "accounts" => [] }
  bot do
    root = Card[ROOT] || stop("no #{ROOT} root on this database")
    bundle["docs"] = ancestry_ids(root.id).filter_map do |id|
      card = Card.fetch(id)
      next unless card
      next if credential_part?(card)
      next if card.name.to_s =~ /\+\*(members|roles|self|right|type|type_plus_right)(\+|\z)/ # scaffolding stays with the refresh

      card_entry(card)
    end
    bundle["nav"] = nav.filter_map { |n| (c = Card[n]) && card_entry(c) }
    stop("a named nav card does not exist") if bundle["nav"].size != nav.size
    bundle["accounts"] = accounts.map do |n|
      user = Card[n] || stop("a named dev account does not exist")
      stop("a named dev account is not a User") unless user.type_id == Card::UserID
      roles = Card::Auth.as(user.id) { Card::Auth.as_card.all_roles }.filter_map { |rid| Card.where(id: rid).first&.name.to_s }
      { "old_id" => user.id, "name" => user.name.to_s, "email" => Card.fetch("#{n}+*account+*email")&.db_content.to_s,
        "roles" => roles - ["Anyone", "Anyone Signed In"] }
    end
  end
  counts = "docs=#{bundle['docs'].size} nav=#{bundle['nav'].size} accounts=#{bundle['accounts'].size}"
  unless ENV["R3_CAPTURE_WRITE"] == "1"
    puts "CAPTURE dry run #{counts}; no file written"
    return
  end
  File.open(FILE, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |f| f.write(JSON.generate(bundle)) }
  File.chmod(0o600, FILE)
  puts "CAPTURED #{counts} mode=600"
  puts "content sha256 prefix: #{Digest::SHA256.file(FILE).hexdigest[0, 16]} (contents not printed)"
end

def apply? = ENV["R3_RESTORE_APPLY"] == "1"

# Written whole and renamed into place, so the file on disk is always complete JSON and always mode 600.
def save_map(map)
  path = ENV.fetch("R3_MAP_FILE")
  File.open("#{path}.tmp", File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |f| f.write(JSON.generate(map)) }
  File.rename("#{path}.tmp", path)
end

# Card.create!, with the object kept. The integrate phase runs from after_commit, so save! can raise with the card already
# durable. The map records such a card, and the error still goes on up.
def create_mapped(entry, map, attributes)
  card = Card.new(attributes)
  begin
    card.save!
  ensure
    if card.id && Card.where(id: card.id).exists?
      map[entry["old_id"].to_s] = card.id
      save_map(map) if apply?
    end
  end
  card
end

# Ids come from this sequence, subcards' included, so starting it here keeps every new id clear of them all.
def clear_id_sequence(bundle)
  conn = ActiveRecord::Base.connection
  old_ids = (bundle["docs"] + bundle["nav"] + bundle["accounts"]).map { |e| Integer(e["old_id"]) }
  floor = [conn.select_value("SELECT last_value FROM cards_id_seq").to_i, OCCUPIED_IDS.end, *old_ids].max
  conn.select_value("SELECT setval('cards_id_seq', #{floor})")
end

def create_fresh(entry, map, skipped)
  if Card[entry["name"]]
    skipped << entry["old_id"]
    return
  end
  card = create_mapped(entry, map, name: entry["name"], type: entry["type"], content: entry["content"])
  stop("a recreated card landed on an occupied id") if OCCUPIED_IDS.cover?(card.id)
end

# Nav cards such as *sidebar exist on every deck, so skipping existing names would lose the dev deck's own. They keep the
# id they have on the staged copy and take the dev content, through the app layer.
def restore_nav(entry, map, skipped, nav_updated)
  card = Card[entry["name"]]
  return create_fresh(entry, map, skipped) unless card

  stop("a nav card has a different type on the staged copy") unless card.type_name.to_s == entry["type"]
  return if card.db_content == entry["content"]

  card.update!(content: entry["content"])
  nav_updated << card.id
end

def create_account(entry, map, skipped)
  if Card[entry["name"]]
    skipped << entry["old_id"]
    return
  end
  user = create_mapped(entry, map, name: entry["name"], type_id: Card::UserID,
                       subcards: { "+*account" => { "+*email" => entry["email"], "+*password" => "R3-#{SecureRandom.hex(24)}aA1!",
                                                    "+*status" => "active" } })
  stop("a recreated account landed on an occupied id") if OCCUPIED_IDS.cover?(user.id)
  entry["roles"].each do |role|
    next unless Card[role]

    members = Card.fetch("#{role}+*members", new: { type: "List" })
    members.add_item!(user.name)
  end
end

# Refusal messages name the setting and never quote the file: it holds card content.
def read_bundle
  stop("R3_PRESERVE_FILE does not name a readable file") unless File.file?(FILE) && File.readable?(FILE)
  bundle = JSON.parse(File.read(FILE))
  stop("R3_PRESERVE_FILE is not a capture file") unless bundle.is_a?(Hash) && %w[docs nav accounts].all? { |k| bundle[k].is_a?(Array) }
  bundle
rescue JSON::ParserError
  stop("R3_PRESERVE_FILE does not hold valid JSON")
end

# The map is written after the commit, so a path that cannot take it has to stop the run before anything commits.
def assert_map_file!
  path = ENV["R3_MAP_FILE"].to_s
  stop("R3_MAP_FILE is not set; --apply writes the reference map there") if path.empty?
  dir = File.dirname(path)
  stop("R3_MAP_FILE is in a directory that cannot be written") unless File.directory?(dir) && File.writable?(dir)
  stop("R3_MAP_FILE already exists; a second apply would replace it, so inspect it by hand") if File.exist?(path)
end

def recreate_all(bundle, map, skipped)
  bot do
    # Parents before children: a compound name needs its left part first.
    nav_updated = []
    nav_names = bundle["nav"].map { |e| e["name"] }
    (bundle["docs"] + bundle["nav"]).sort_by { |e| e["name"].count("+") }.each do |e|
      nav_names.include?(e["name"]) ? restore_nav(e, map, skipped, nav_updated) : create_fresh(e, map, skipped)
    end
    bundle["accounts"].each { |e| create_account(e, map, skipped) }
    puts "NAV updated=#{nav_updated.size} ids=#{nav_updated.sort.join(',')}"
  end
  missing = map.values.reject { |id| Card.where(id: id).exists? }
  stop("recreated cards are missing: #{missing.size}") unless missing.empty?
  reused = map.select { |old, fresh| old.to_i == fresh }
  stop("a recreated card kept its old id") unless reused.empty?
  puts "RESTORE created=#{map.size} skipped_existing=#{skipped.size} apply=#{apply?}"
end

def restore_apply(bundle, map, skipped)
  assert_map_file!
  save_map(map) # mode 600 and proven writable before the first commit
  clear_id_sequence(bundle)
  begin
    recreate_all(bundle, map, skipped)
  rescue StandardError => e
    puts "RESTORE stopped: #{map.size} cards committed and mapped (#{e.class}). " \
         "The staged copy is partial: drop it, restore it from the dump again, delete the map file."
    raise
  end
  puts "reference map written: #{map.size} entries, mode 600"
end

def restore_dry_run(bundle, map, skipped)
  conn = ActiveRecord::Base.connection
  seq = conn.select_one("SELECT last_value, is_called FROM cards_id_seq")
  clear_id_sequence(bundle)
  ActiveRecord::Base.transaction do
    recreate_all(bundle, map, skipped)
    raise ActiveRecord::Rollback
  end
  puts "dry run: rolled back; no reference map written"
ensure
  conn.select_value("SELECT setval('cards_id_seq', #{seq['last_value'].to_i}, #{seq['is_called'].to_s.start_with?('t')})") if seq
end

def restore
  assert_staged!
  bundle = read_bundle
  map = {}
  skipped = []
  # A committed card now runs its integrate phase, and that can deliver mail from rules in the data. Decko's own card
  # loader turns mail off the same way.
  Card::Mailer.perform_deliveries = false
  puts "mail delivery: #{Card::Mailer.perform_deliveries ? 'on' : 'off'}"
  apply? ? restore_apply(bundle, map, skipped) : restore_dry_run(bundle, map, skipped)
end

case STEP
when "capture" then capture
when "restore" then restore
else stop("R3_PRESERVE_STEP must be capture or restore")
end
$stdout.flush
exit!(0)
