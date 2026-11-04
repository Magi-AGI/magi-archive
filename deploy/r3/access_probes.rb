# frozen_string_literal: true

# R3 access probes, after the refresh, on the staged database. Read-only: it holds the session read-only at the database
# level. Proves excluded data is gone and retained cards are readable by the right principals. Prints ids and counts only.
#
# Env: R3_MANIFEST (strict manifest json), R3_FILES_DIR, optional R3_MAP_FILE (restore's reference map: those accounts
#      legitimately have fresh credentials), optional R3_DEV_ACCOUNTS (names that must exist after recreation),
#      optional R3_PROBE_SAMPLE (cards per probe, default 300).
require "json"

$failures = 0
def check(label, ok, detail = nil)
  $failures += 1 unless ok
  puts "#{ok ? 'PASS' : 'FAIL'} #{label}#{ok ? '' : " :: #{detail.inspect[0, 160]}"}"
end

conn = ActiveRecord::Base.connection
db = conn.current_database
unless db.end_with?("_staged")
  warn "REFUSED: probes run only on a database named *_staged"
  $stdout.flush
  exit!(2)
end
conn.execute("SET SESSION default_transaction_read_only = on")
puts "database: #{db} (session read-only)"

manifest = JSON.parse(File.read(ENV.fetch("R3_MANIFEST")))
excluded = manifest.fetch("excluded_ids").map(&:to_i)
list = excluded.empty? ? "0" : excluded.join(",")
count = ->(sql) { conn.select_value(sql).to_i }

puts "--- excluded data is gone (#{excluded.size} ids)"
check "no excluded card row remains", count.call("SELECT count(*) FROM cards WHERE id IN (#{list})").zero?
check "no action history remains", count.call("SELECT count(*) FROM card_actions WHERE card_id IN (#{list})").zero?
check "no reference remains", count.call("SELECT count(*) FROM card_references WHERE referer_id IN (#{list}) OR referee_id IN (#{list})").zero?
check "no virtual-card derivative remains", count.call("SELECT count(*) FROM card_virtuals WHERE left_id IN (#{list}) OR right_id IN (#{list})").zero?
check "nothing retained points at an excluded card",
      count.call("SELECT count(*) FROM cards WHERE left_id IN (#{list}) OR right_id IN (#{list}) OR type_id IN (#{list}) OR read_rule_id IN (#{list})").zero?
store = ENV["R3_FILES_DIR"]
if store
  left = manifest.fetch("attachment_card_ids").count { |i| File.exist?(File.join(store, i.to_s)) || File.exist?(File.join(store, "~#{i}")) }
  check "no excluded attachment remains in the store", left.zero?, left
else
  puts "SKIP attachment store check: R3_FILES_DIR not set"
end

puts "--- credentials are sanitized (absence checks)"
fresh = ENV["R3_MAP_FILE"].to_s.empty? ? [] : JSON.parse(File.read(ENV["R3_MAP_FILE"])).values.map { |v| Integer(v) }
fresh_list = fresh.empty? ? "0" : fresh.join(",")
fresh_accounts = "SELECT id FROM cards WHERE left_id IN (#{fresh_list})"
secret_rights = "SELECT id FROM cards WHERE codename IN ('password','salt','api_key','token','reset_token')"
check "no secret value remains outside the recreated accounts",
      count.call("SELECT count(*) FROM cards WHERE right_id IN (#{secret_rights}) AND coalesce(db_content,'') <> '' " \
                 "AND coalesce(left_id,0) NOT IN (#{fresh_accounts})").zero?
check "no unsanitized account email remains outside the recreated accounts",
      count.call("SELECT count(*) FROM cards c JOIN cards l ON l.id = c.left_id " \
                 "WHERE c.right_id IN (SELECT id FROM cards WHERE codename = 'email') " \
                 "AND l.right_id IN (SELECT id FROM cards WHERE codename = 'account') " \
                 "AND c.db_content !~ '^sanitized\\+[0-9]+@invalid\\.invalid$' AND c.left_id NOT IN (#{fresh_accounts})").zero?
check "no users row holds a credential",
      count.call("SELECT count(*) FROM users WHERE crypted_password IS NOT NULL OR salt IS NOT NULL OR password_reset_code IS NOT NULL OR email IS NOT NULL").zero?

puts "--- retained cards are readable by the right principals"
# Expectations come from each card's own rule, read as bot, then the card is asked as that principal.
sample = Integer(ENV.fetch("R3_PROBE_SAMPLE", "300"))
rule_items = Hash.new do |h, rule_id|
  h[rule_id] = Card::Auth.as_bot { Card.fetch(rule_id)&.item_names.to_a.map { |n| n.to_name.key } }
end
live = Card.where(trash: false).where.not(read_rule_id: nil).pluck(:id, :read_rule_id)
public_cards, restricted_cards = live.partition { |_id, rule| rule_items[rule].include?("anyone") }
pick = ->(rows) { rows.each_slice([rows.size / [sample, 1].max, 1].max).map(&:first).first(sample) }
public_ids = pick.call(public_cards).map(&:first)
restricted = pick.call(restricted_cards)
puts "live cards with a rule: public=#{public_cards.size} restricted=#{restricted_cards.size}; sampled #{public_ids.size} and #{restricted.size}"
readable = ->(principal, id) { Card::Auth.as(principal) { Card.fetch(id)&.ok?(:read) } }

check "a sample of public cards exists", public_ids.any?
denied = public_ids.reject { |i| readable.call(Card::AnonymousID, i) }
check "Anonymous can read every sampled public card", denied.empty?, denied.first(5)
leaked = restricted.map(&:first).select { |i| readable.call(Card::AnonymousID, i) }
check "Anonymous cannot read any sampled restricted card", leaked.empty?, leaked.first(5)

# A principal the rule names: the first non-admin member of a role in it, or a user named directly.
admin_id = Card::AdministratorID
principal_for = Hash.new do |h, rule_id|
  h[rule_id] = Card::Auth.as_bot do
    rule_items[rule_id].lazy.filter_map do |item|
      c = Card.fetch(item)
      next unless c
      next c.id if c.type_id == Card::UserID
      next unless c.type_id == Card::RoleID && c.id != admin_id

      Card.fetch("#{c.name}+*members")&.item_ids.to_a.find { |m| Card.where(id: m, trash: false).exists? }
    end.first
  end
end
with_principal = restricted.select { |_id, rule| principal_for[rule] }
refused = with_principal.reject { |id, rule| readable.call(principal_for[rule], id) }.map(&:first)
check "a principal named by the rule can read each restricted card (#{with_principal.size} of #{restricted.size} have one)",
      refused.empty?, refused.first(5)

ENV.fetch("R3_DEV_ACCOUNTS", "").split(",").map(&:strip).reject(&:empty?).each_with_index do |name, i|
  check "preserved dev account #{i + 1} exists as a User", Card[name]&.type_id == Card::UserID
end

puts "PROBES FAILURES=#{$failures}"
$stdout.flush
exit!($failures.zero? ? 0 : 1)
