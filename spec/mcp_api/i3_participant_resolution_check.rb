#!/usr/bin/env ruby
# frozen_string_literal: true

# ================================================================================================
# STANDALONE, RUNNABLE PROOF for the `~k` participant-resolution repair in
# mod/mcp_api/app/controllers/api/mcp/i3_read_controller.rb
#
# WHY THIS FILE EXISTS AT ALL. `bundle exec rspec` is UNRUNNABLE in this worktree: `bundle check`
# reports ~40 missing gems (decko 0.20.0, card 1.110.0, actionpack 7.2.3.1, ...), the same reason
# i3_envelope_integration_harness.rb:28-30 records. The rspec cases added alongside this file
# (spec/mcp_api/controllers/i3_read_controller_spec.rb) are therefore WRITTEN BUT UNRUN until a
# booted environment exists. This file closes that gap with plain ruby and NO dependencies: it
# runs today, locally, on the REAL method bodies.
#
# IT EXERCISES THE REAL LOGIC, NOT A RESTATEMENT OF IT. The three methods under test
# (#resolve_participant_reference!, #resolve_participant_key_reference!, #card_id_from_store_key_text)
# are EXTRACTED VERBATIM from the controller source at load time by #extract_method below and
# `class_eval`'d into a bare harness class. If the controller's text changes, this test changes
# with it; if the extraction fails to find a method, the test ERRORS rather than passing vacuously.
# Only the COLLABORATORS are stubbed (readable_source?, readable_identity_for_name,
# render_acl_empty, render_bad_request, render_unavailable), and each records its call so the
# assertions can prove WHICH exit was taken -- which is the actual property at issue.
#
# WHAT IT PROVES
#   1. `~k(Card 2)` resolves to id 2 THROUGH readable_source? (the bug: it used to go to the NAME
#      resolver, which could never match a key text, so this always answered empty).
#   2. The same key with readable_source? false answers the empty shape.
#   3. Malformed `~k` keys -- `(Card 0)`, `rich_text+description`, `(Card abc)`, `` -- all answer
#      the empty shape and NEVER attempt a card read.
#   4. The three empty cases are BYTE-IDENTICAL to each other (the no-oracle property): absent,
#      unreadable and unmappable are indistinguishable.
#   5. The legacy bare-name path still resolves via readable_identity_for_name, unchanged.
#   6. The `~<id>` numeric path is unchanged and touches neither resolver.
#   7. The `~d` digest branch is still a declared capability gap.
#
# RUN: ruby spec/mcp_api/i3_participant_resolution_check.rb
# ================================================================================================

require "pathname"

ROOT = Pathname.new(__dir__).parent.parent
CONTROLLER = ROOT.join("mod/mcp_api/app/controllers/api/mcp/i3_read_controller.rb")

abort "FATAL: controller not found at #{CONTROLLER}" unless CONTROLLER.file?
SOURCE = CONTROLLER.read

# Pull one `def name ... end` out of the controller source by matching its indentation, so the
# harness runs the SHIPPING method body rather than a hand-copied paraphrase of it.
def extract_method(source, name)
  lines = source.lines
  start = lines.index { |l| l =~ /^(\s*)def #{Regexp.escape(name)}(?:\(|\s|$)/ }
  raise "method ##{name} not found in controller source" unless start

  indent = lines[start][/^\s*/].length
  stop = ((start + 1)...lines.length).find do |i|
    lines[i] =~ /^\s{#{indent}}end\s*$/
  end
  raise "could not find end of ##{name}" unless stop

  lines[start..stop].map { |l| l.sub(/^\s{#{indent}}/, "") }.join
end

EXTRACTED = %w[
  resolve_participant_reference!
  resolve_participant_key_reference!
  card_id_from_store_key_text
].to_h { |m| [m, extract_method(SOURCE, m)] }

# ------------------------------------------------------------------------------------------------
# The harness: real method bodies, stubbed collaborators, every render recorded.
# ------------------------------------------------------------------------------------------------
class Harness
  attr_reader :renders, :acl_checked, :names_resolved

  # @param readable [Boolean] what readable_source? answers
  # @param known_names [Hash] name => card_id for readable_identity_for_name
  def initialize(readable: true, known_names: {})
    @readable = readable
    @known_names = known_names
    @renders = []
    @acl_checked = []
    @names_resolved = []
  end

  Identity = Struct.new(:card_id, :name)

  # --- stubbed collaborators (each records, so the test can assert the EXIT TAKEN) ---
  def readable_source?(card_id)
    @acl_checked << card_id
    @readable
  end

  def readable_identity_for_name(name)
    @names_resolved << name
    id = @known_names[name]
    id ? Identity.new(id, name) : nil
  end

  def render_acl_empty
    # The REAL render_acl_empty takes NO arguments and derives its triple from STORE's I2-01
    # status; what matters here is that the recorded answer carries NOTHING case-specific.
    @renders << { render: :acl_empty }
    nil
  end

  def render_bad_request(reason)
    @renders << { render: :bad_request, reason: reason }
    nil
  end

  def render_unavailable(reason)
    @renders << { render: :unavailable, reason: reason }
    nil
  end

  class_eval EXTRACTED["resolve_participant_reference!"]
  class_eval EXTRACTED["resolve_participant_key_reference!"]
  class_eval EXTRACTED["card_id_from_store_key_text"]
end

# ------------------------------------------------------------------------------------------------
# Tiny assertion runner
# ------------------------------------------------------------------------------------------------
PASS = []
FAIL = []

def check(label)
  ok, detail = yield
  if ok
    PASS << label
    puts "  PASS  #{label}"
  else
    FAIL << "#{label} -- #{detail}"
    puts "  FAIL  #{label}\n          #{detail}"
  end
rescue StandardError => e
  FAIL << "#{label} -- RAISED #{e.class}: #{e.message}"
  puts "  ERROR #{label}\n          RAISED #{e.class}: #{e.message}"
end

puts "i3 participant resolution check"
puts "controller: #{CONTROLLER}"
puts "extracted : #{EXTRACTED.keys.join(', ')}"
puts

# === 1. the repaired happy path ==================================================================
puts "[1] `~k(Card 2)` resolves to id 2 via readable_source?"
h = Harness.new(readable: true)
got = h.resolve_participant_reference!("~k(Card 2)")
check("returns card id 2") { [got == 2, "got #{got.inspect}"] }
check("authorized through readable_source?(2)") { [h.acl_checked == [2], "acl_checked=#{h.acl_checked.inspect}"] }
check("nothing rendered (request proceeds)") { [h.renders.empty?, "renders=#{h.renders.inspect}"] }
check("NAME resolver never consulted for a key text") do
  [h.names_resolved.empty?, "names_resolved=#{h.names_resolved.inspect}"]
end
puts

# === 2. same key, caller may not read ============================================================
puts "[2] `~k(Card 2)` when readable_source? is false"
unreadable = Harness.new(readable: false)
got = unreadable.resolve_participant_reference!("~k(Card 2)")
check("returns nil") { [got.nil?, "got #{got.inspect}"] }
check("ACL was consulted") { [unreadable.acl_checked == [2], "acl_checked=#{unreadable.acl_checked.inspect}"] }
check("rendered the acl-empty answer") do
  [unreadable.renders == [{ render: :acl_empty }], "renders=#{unreadable.renders.inspect}"]
end
puts

# === 3. malformed keys fail closed, with NO card read ============================================
puts "[3] malformed `~k` keys fail closed"
MALFORMED = ["~k(Card 0)", "~krich_text+description", "~k(Card abc)", "~k"].freeze
malformed_runs = MALFORMED.to_h do |ref|
  hh = Harness.new(readable: true)
  [ref, { result: hh.resolve_participant_reference!(ref), renders: hh.renders,
          acl: hh.acl_checked, names: hh.names_resolved }]
end

MALFORMED.each do |ref|
  r = malformed_runs[ref]
  check("#{ref.inspect} returns nil") { [r[:result].nil?, "got #{r[:result].inspect}"] }
  check("#{ref.inspect} attempted NO card read") { [r[:acl].empty?, "acl_checked=#{r[:acl].inspect}"] }
  check("#{ref.inspect} attempted NO name resolution") { [r[:names].empty?, "names=#{r[:names].inspect}"] }
  check("#{ref.inspect} rendered acl_empty") do
    [r[:renders] == [{ render: :acl_empty }], "renders=#{r[:renders].inspect}"]
  end
end
puts

# === 4. THE NO-ORACLE PROPERTY: absent / unreadable / unmappable are byte-identical ==============
puts "[4] no-oracle: absent, unreadable and unmappable are byte-identical"
absent = Harness.new(readable: true, known_names: {})
absent.resolve_participant_reference!("No Such Card Name")

answers = {
  "absent (bare name miss)" => absent.renders,
  "unreadable (~k(Card 2), denied)" => unreadable.renders,
  "unmappable (~k(Card 0))" => malformed_runs["~k(Card 0)"][:renders],
  "unmappable (~krich_text+description)" => malformed_runs["~krich_text+description"][:renders],
  "unmappable (~k(Card abc))" => malformed_runs["~k(Card abc)"][:renders],
  "unmappable (~k)" => malformed_runs["~k"][:renders]
}
serialized = answers.transform_values(&:inspect)
distinct = serialized.values.uniq
check("all #{answers.size} empty answers are byte-identical") do
  [distinct.length == 1, "distinct forms=#{serialized.inspect}"]
end
check("that single answer carries no case-specific reason") do
  [distinct.first == [{ render: :acl_empty }].inspect, "answer=#{distinct.first}"]
end
puts

# === 5. legacy bare-name path unchanged ==========================================================
puts "[5] legacy bare name still resolves via readable_identity_for_name"
named = Harness.new(readable: true, known_names: { "Home" => 17_120 })
got = named.resolve_participant_reference!("Home")
check("returns the resolved id") { [got == 17_120, "got #{got.inspect}"] }
check("went through the NAME resolver") { [named.names_resolved == ["Home"], "names=#{named.names_resolved.inspect}"] }
check("did NOT go through readable_source?") { [named.acl_checked.empty?, "acl=#{named.acl_checked.inspect}"] }
check("nothing rendered") { [named.renders.empty?, "renders=#{named.renders.inspect}"] }

blank = Harness.new
got = blank.resolve_participant_reference!("   ")
check("whitespace-only name -> 400 participant_malformed") do
  [blank.renders == [{ render: :bad_request, reason: "participant_malformed" }] && got.nil?,
   "got=#{got.inspect} renders=#{blank.renders.inspect}"]
end
puts

# === 6. `~<id>` numeric path unchanged ===========================================================
puts "[6] `~<id>` numeric path unchanged"
num = Harness.new(readable: false) # readable? must be irrelevant: the gate is the CALLER's, later
got = num.resolve_participant_reference!("~42")
check("`~42` returns 42") { [got == 42, "got #{got.inspect}"] }
check("resolves without rendering") { [num.renders.empty?, "renders=#{num.renders.inspect}"] }
check("defers its ACL to the caller gate (no check here)") do
  [num.acl_checked.empty? && num.names_resolved.empty?,
   "acl=#{num.acl_checked.inspect} names=#{num.names_resolved.inspect}"]
end
puts

# === 7. `~d` digest branch is still a declared gap ===============================================
puts "[7] `~d` digest branch still a declared capability gap"
dig = Harness.new
got = dig.resolve_participant_reference!("~d0123456789abcdef0123456789abcdef")
check("returns nil") { [got.nil?, "got #{got.inspect}"] }
check("renders the digest-unavailable gap") do
  [dig.renders == [{ render: :unavailable, reason: "i3_participant_digest_resolution_unavailable" }],
   "renders=#{dig.renders.inspect}"]
end
check("no card touched") { [dig.acl_checked.empty?, "acl=#{dig.acl_checked.inspect}"] }
puts

# === 8. the shared mapper itself =================================================================
puts "[8] card_id_from_store_key_text is strict and shared"
m = Harness.new
{
  "(Card 2)" => 2,
  "(Card 17120)" => 17_120,
  "(Card 0)" => nil,
  "(Card 02)" => 2,
  "(Card -1)" => nil,
  "(Card abc)" => nil,
  "(Card 2) " => nil,
  " (Card 2)" => nil,
  "(Card 2)x" => nil,
  "(Wanted \"missing\")" => nil,
  "rich_text+description" => nil,
  "" => nil,
  "Card 2" => nil
}.each do |text, want|
  check("map #{text.inspect} -> #{want.inspect}") do
    got = m.card_id_from_store_key_text(text)
    [got == want, "got #{got.inspect}"]
  end
end
check("map nil -> nil (non-String)") { [m.card_id_from_store_key_text(nil).nil?, "non-nil"] }
check("map 2 -> nil (non-String)") { [m.card_id_from_store_key_text(2).nil?, "non-nil"] }
puts

# ------------------------------------------------------------------------------------------------
puts "=" * 72
puts "PASSED: #{PASS.length}   FAILED: #{FAIL.length}"
unless FAIL.empty?
  puts
  puts "FAILURES:"
  FAIL.each { |f| puts "  - #{f}" }
end
puts "=" * 72
exit(FAIL.empty? ? 0 : 1)
