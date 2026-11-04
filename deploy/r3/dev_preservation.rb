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
# all the work in a transaction and rolls it back. Prints ids, counts and classes, never content or emails.
#
# Env: R3_PRESERVE_FILE, R3_MAP_FILE, R3_DEV_ACCOUNTS (comma-separated names), R3_DEV_NAV_CARDS (optional, comma-separated).
require "json"
require "securerandom"
require "digest"

STEP = ENV.fetch("R3_PRESERVE_STEP")
FILE = ENV.fetch("R3_PRESERVE_FILE")
ROOT = "Administrator"
# Occupied by retained production GM cards on dev; a card created here must never land on one of them.
OCCUPIED_IDS = (10_986..11_013).freeze

def bot(&block) = Card::Auth.as_bot(&block)
def stop(message)
  warn "REFUSED: #{message}"
  $stdout.flush
  exit!(2)
end

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
  accounts = ENV.fetch("R3_DEV_ACCOUNTS").split(",").map(&:strip).reject(&:empty?)
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

def create_fresh(entry, map, skipped)
  if Card[entry["name"]]
    skipped << entry["old_id"]
    return
  end
  card = Card.create!(name: entry["name"], type: entry["type"], content: entry["content"])
  stop("a recreated card landed on an occupied id") if OCCUPIED_IDS.cover?(card.id)
  map[entry["old_id"].to_s] = card.id
end

def create_account(entry, map, skipped)
  if Card[entry["name"]]
    skipped << entry["old_id"]
    return
  end
  user = Card.create!(name: entry["name"], type_id: Card::UserID,
                      subcards: { "+*account" => { "+*email" => entry["email"], "+*password" => "R3-#{SecureRandom.hex(24)}aA1!",
                                                   "+*status" => "active" } })
  stop("a recreated account landed on an occupied id") if OCCUPIED_IDS.cover?(user.id)
  map[entry["old_id"].to_s] = user.id
  entry["roles"].each do |role|
    next unless Card[role]

    members = Card.fetch("#{role}+*members", new: { type: "List" })
    members.add_item!(user.name)
  end
end

def restore
  assert_staged!
  bundle = JSON.parse(File.read(FILE))
  map = {}
  skipped = []
  apply = ENV["R3_RESTORE_APPLY"] == "1"
  ActiveRecord::Base.transaction do
    bot do
      # Parents before children: a compound name needs its left part first.
      entries = (bundle["docs"] + bundle["nav"]).sort_by { |e| e["name"].count("+") }
      entries.each { |e| create_fresh(e, map, skipped) }
      bundle["accounts"].each { |e| create_account(e, map, skipped) }
    end
    missing = map.values.reject { |id| Card.exists?(id: id) }
    stop("recreated cards are missing: #{missing.size}") unless missing.empty?
    reused = map.select { |old, fresh| old.to_i == fresh }
    stop("a recreated card kept its old id") unless reused.empty?
    puts "RESTORE created=#{map.size} skipped_existing=#{skipped.size} apply=#{apply}"
    raise ActiveRecord::Rollback unless apply
  end
  if apply
    map_file = ENV.fetch("R3_MAP_FILE")
    File.open(map_file, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |f| f.write(JSON.generate(map)) }
    puts "reference map written: #{map.size} entries, mode 600"
  else
    puts "dry run: rolled back; no reference map written"
  end
end

case STEP
when "capture" then capture
when "restore" then restore
else stop("R3_PRESERVE_STEP must be capture or restore")
end
$stdout.flush
exit!(0)
