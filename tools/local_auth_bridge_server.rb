# frozen_string_literal: true

# THE RUBY HALF OF A REAL, LOCAL, CROSS-PROCESS AUTHORIZATION BOUNDARY EXERCISE.
#
# WHAT THIS IS. A plain Ruby process that answers the two authorization questions VIEW's Python
# resolver asks, over STDIN/STDOUT newline-delimited JSON. It is driven by
# `tools/local_bridge_exercise.py`, which runs the REAL `decko_bridge.DeckoCardAuthorizer` and
# `DeckoCardReadAuthorizer` against it. So the Python side's injected transport is, for this
# exercise, an ACTUAL SEPARATE OS PROCESS -- not a Python fake.
#
# WHY IT IS NOT HTTP, AND WHY THAT IS THE HONEST CHOICE. The deck's I3 surface is a Rails
# controller; running it needs a booted Rails with PostgreSQL, and neither is available in this
# environment (no usable `gem`/`bundle`, no PG). Standing up a fake HTTP server here would prove
# nothing about Rails and would invite the reading that the real endpoint was exercised. So the
# transport is STDIO, the AUTHORIZATION LOGIC is the real
# `Atomspace::CallerScopedCardAuthorization`, and what is NOT exercised (Rails, routing, status
# mapping, real Decko ACLs, request-identity isolation under concurrency) is stated plainly rather
# than simulated.
#
# WHAT IS GENUINELY PROVEN BY RUNNING IT:
#   * the real Ruby module and the real Python bridge AGREE ON A PAYLOAD SHAPE across a process
#     boundary -- the canonical name arrives in Decko's own field and builds an AuthorizedCard;
#   * CALLER IDENTITY IS CARRIED PER REQUEST: every request names its principal, each is answered
#     under that principal, and a card readable by one caller is not readable by another;
#   * absent and unreadable are INDISTINGUISHABLE on the wire;
#   * a transport/backend failure is a typed REFUSAL on the Python side, never `None`;
#   * a service-account principal is REFUSED, and an elevation marker is never emitted;
#   * an unwired backend FAILS CLOSED.
#
# NO CREDENTIALS, NO NETWORK, NO HOST. This process binds no socket and reads no secret.

require "json"

LIB = File.expand_path("../mod/mcp_api/lib/atomspace", __dir__)
require File.join(LIB, "errors")
require File.join(LIB, "mirror_readiness")
require File.join(LIB, "authorized_card_identity")

# ------------------------------------------------------------------------------------------
# A local in-memory card world. This stands in for the DATABASE, not for the ACL logic: the
# authorization decisions below are made by the REAL CallerScopedCardAuthorization module.
# ------------------------------------------------------------------------------------------

CardRow = Struct.new(:id, :canonical_name, :readers, :aliases, keyword_init: true)

WORLD = [
  # "MCP Admin" is reachable by three alias spellings, as Cardname would make it.
  CardRow.new(id: 17_120, canonical_name: "MCP Admin", readers: %w[alice],
              aliases: ["mcp_admin", "mcp-admin", "MCP Admin"]),
  CardRow.new(id: 101, canonical_name: "Ada Lovelace", readers: %w[alice bob],
              aliases: ["Ada Lovelace", "ada_lovelace"]),
  # Readable by bob ONLY. This is the per-caller discrimination the exercise checks.
  CardRow.new(id: 102, canonical_name: "Bob Private", readers: %w[bob],
              aliases: ["Bob Private"]),
  # Readable by NOBODY: must be indistinguishable from absent.
  CardRow.new(id: 103, canonical_name: "Sealed", readers: [], aliases: ["Sealed"])
].freeze

SERVICE_ACCOUNTS = %w[mcp-user mcp-gm mcp-admin].freeze

BY_ALIAS = WORLD.each_with_object({}) { |row, h| row.aliases.each { |a| h[a] = row } }.freeze
BY_ID = WORLD.each_with_object({}) { |row, h| h[row.id] = row }.freeze

# A card double exposing exactly what AuthorizedCardIdentity.from_card reads.
class LiveLikeCard
  def initialize(row, principal)
    @row = row
    @principal = principal
  end

  def id = @row.id
  # Deliberately NOT a String, matching Decko's Cardname.
  def name = CardnameLike.new(@row.canonical_name)
  def new_card? = false
  def read_rule_id = 1
  def ok?(action)
    raise "unexpected #{action}" unless action == :read

    @row.readers.include?(@principal)
  end
end

class CardnameLike
  def initialize(text) = @text = text
  def to_s = @text
end

# The identity stack the real module drives. Recorded so the exercise can assert that every
# answer was computed under the REQUESTING principal and that the stack never leaks.
module IdentityStack
  class << self
    def stack = (@stack ||= [])
    def current = stack.last
    def as(name)
      stack.push(name.to_s)
      yield
    ensure
      stack.pop
    end
  end
end

# Install the Card/Card::Auth surface the real module calls. `Card.fetch` resolves under the
# identity currently in effect, exactly as Decko's would.
class Card
  def self.fetch(key)
    principal = IdentityStack.current
    row = key.is_a?(Integer) ? BY_ID[key] : BY_ALIAS[key.to_s]
    row && LiveLikeCard.new(row, principal)
  end

  Auth = IdentityStack
end

require File.join(LIB, "caller_scoped_card_authorization")

CSA = Atomspace::CallerScopedCardAuthorization

# The concern's own default-deny rule.
READABLE = lambda do |card|
  next false if card.nil? || card.new_card? || card.read_rule_id.to_s.strip.empty?

  card.ok?(:read)
end

Account = Struct.new(:name)

# ------------------------------------------------------------------------------------------
# The request loop. One JSON object per line in, one per line out.
# ------------------------------------------------------------------------------------------

# Simulates the deployment state in which the backend read port is not bound. The AUTH answer is
# still computable (it is deck-side only), so this flag exists to prove the two are DISTINCT: a
# backend outage must not read as a permission denial.
backend_unwired = false

$stdout.sync = true

while (line = $stdin.gets)
  line = line.strip
  next if line.empty?

  begin
    req = JSON.parse(line)
  rescue JSON::ParserError => e
    puts JSON.generate({ "status" => 400, "body" => { "error" => "unparseable_request" },
                         "detail" => e.class.name })
    next
  end

  op = req["op"]
  principal = req["principal"].to_s

  begin
    case op
    when "set_backend_unwired"
      backend_unwired = !!req["value"]
      puts JSON.generate({ "status" => 200, "body" => { "ok" => true } })
      next

    when "lookup"
      # PRINCIPAL GATE FIRST, exactly as the controller orders it: a service account is refused
      # before any data is touched. The deck's own rule (i3_read_controller.rb:357-371) excludes
      # service accounts by canonical identity; here the configured names are compared after the
      # same strip, and a refusal is a 403 with NO data and NO elevation marker.
      if SERVICE_ACCOUNTS.include?(principal.strip)
        puts JSON.generate({ "status" => 403,
                             "body" => { "error" => "principal_not_permitted" } })
        next
      end
      if principal.strip.empty?
        puts JSON.generate({ "status" => 401, "body" => { "error" => "principal_unresolved" } })
        next
      end

      identity = CSA.readable_identity_for_name(
        req["name"].to_s, account: Account.new(principal), readable: READABLE
      )
      body = if identity.nil?
               # ABSENT AND UNREADABLE COLLAPSE. `found: false` is the Python bridge's
               # ABSENT_FLAG_FIELDS signal and maps to None.
               { "found" => false }
             else
               # Decko's OWN canonical field. No "name" key: the request string is never echoed.
               identity.to_authorization_payload.merge("found" => true)
             end
      puts JSON.generate({ "status" => 200, "body" => body })
      next

    when "readable"
      if SERVICE_ACCOUNTS.include?(principal.strip) || principal.strip.empty?
        puts JSON.generate({ "status" => 403,
                             "body" => { "error" => "principal_not_permitted" } })
        next
      end
      # A BACKEND OUTAGE IS REPORTED AS 503, NOT AS readable=false. The Python gate denies on it
      # either way (uncertainty denies), but the two are distinguishable to an operator.
      if backend_unwired
        puts JSON.generate({ "status" => 503,
                             "body" => { "error" => "i3_backend_unavailable",
                                         "reason" => "i3_read_port_unwired" } })
        next
      end

      allowed = CSA.readable_card_id?(
        req["card_id"], account: Account.new(principal), readable: READABLE
      )
      puts JSON.generate({ "status" => 200, "body" => { "readable" => allowed } })
      next

    when "identity_stack"
      # Proof the identity stack does not leak between requests.
      puts JSON.generate({ "status" => 200,
                           "body" => { "depth" => IdentityStack.stack.length } })
      next

    when "quit"
      puts JSON.generate({ "status" => 200, "body" => { "bye" => true } })
      break

    else
      puts JSON.generate({ "status" => 400, "body" => { "error" => "unknown_op" } })
      next
    end
  rescue Atomspace::InvalidRequest => e
    # Ruby's own name_required: a client error, NOT a denial and NOT a backend condition.
    puts JSON.generate({ "status" => 400,
                         "body" => { "error" => "bad_request", "reason" => e.message } })
  rescue Atomspace::AuthorizedCardIdentity::Incomplete => e
    # A framework contract violation. 500, and explicitly NOT found:false -- an authorized card
    # that cannot state its identity must never be reported as unreadable.
    puts JSON.generate({ "status" => 500,
                         "body" => { "error" => "identity_incomplete" }, "detail" => e.message })
  rescue CSA::PrincipalUnusable => e
    puts JSON.generate({ "status" => 401,
                         "body" => { "error" => "principal_unresolved" }, "detail" => e.message })
  rescue StandardError => e
    # NOTHING derived from the exception reaches the body: the deck's own containment rule
    # (i3_read_controller.rb:502-512) exists because Card/AR messages name cards and columns.
    warn "bridge server error: #{e.class}: #{e.message}"
    puts JSON.generate({ "status" => 500, "body" => { "error" => "i3_internal_error" } })
  end
end
