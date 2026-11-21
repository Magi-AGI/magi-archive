# frozen_string_literal: true

# STANDALONE unit spec -- NO Rails, NO Decko, NO DB, NO sidecar.
#
# Deliberately does NOT `require "spec_helper"` (which boots config/environment and therefore needs
# the full decko/card gem set). It loads only pure-Ruby files, so it is RUNNABLE on a host where
# `bundle check` reports missing gems:
#
#   ruby -S rspec spec/mcp_api/lib/i3_read_port_spec.rb
#
# It locks the two fail-closed behaviours that must not regress even if the Rails boot is broken:
# the grant/scope function, and the I3 port's fail-closed readiness + no-local-digest contract.

require "ostruct"

lib = File.expand_path("../../../mod/mcp_api/lib", __dir__)

# Minimal ActiveSupport-free stand-ins for the two helpers these pure-Ruby files use.
unless Object.new.respond_to?(:present?)
  class Object
    def blank? = respond_to?(:empty?) ? !!empty? : !self
    def present? = !blank?
  end

  class NilClass
    def blank? = true
    def present? = false
  end

  class String
    def blank? = strip.empty?
  end
end

require File.join(lib, "mcp_api/atomspace_grants")
require File.join(lib, "atomspace/errors")

# MirrorReadiness references Decko models lazily inside probes, so requiring it is safe; only
# Result / READY are touched here.
require File.join(lib, "atomspace/mirror_readiness")
require File.join(lib, "atomspace/i3_read_port")
require File.join(lib, "atomspace/fixture_i3_read_port")

RSpec.describe "I3 pure-ruby contracts" do
  around do |example|
    vars = %w[I3_READ_GRANTS ATOMSPACE_READ_GRANTS ATOMSPACE_ADMIN_GRANTS]
    saved = vars.to_h { |v| [v, ENV[v]] }
    vars.each { |v| ENV.delete(v) }
    example.run
  ensure
    saved.each { |v, val| val.nil? ? ENV.delete(v) : ENV[v] = val }
  end

  let(:user_card) { Object.new.tap { |o| o.define_singleton_method(:name) { "Alice" } } }

  describe McpApi::AtomspaceGrants do
    it "mints mcp:i3:read only for an allowlisted real user" do
      ENV["I3_READ_GRANTS"] = "user:Alice"
      expect(described_class.scopes_for("user:Alice", user_card: user_card)).to eq(["mcp:i3:read"])
    end

    it "mints nothing for an unlisted user" do
      expect(described_class.scopes_for("user:Alice", user_card: user_card)).to eq([])
    end

    # A key token never gets the scope: no user_card -> the precondition fails.
    it "never mints mcp:i3:read for a key principal, even when allowlisted" do
      ENV["I3_READ_GRANTS"] = "key:123,user:Alice"
      expect(described_class.scopes_for("key:123")).to eq([])
      expect(described_class.scopes_for("key:123", user_card: nil)).to eq([])
    end

    it "does not let an I3 grant confer any atomspace scope" do
      ENV["I3_READ_GRANTS"] = "user:Alice"
      scopes = described_class.scopes_for("user:Alice", user_card: user_card)
      expect(scopes).not_to include("mcp:atomspace:read", "mcp:atomspace:admin")
    end

    it "does not let an atomspace grant confer the I3 scope" do
      ENV["ATOMSPACE_ADMIN_GRANTS"] = "user:Alice"
      scopes = described_class.scopes_for("user:Alice", user_card: user_card)
      expect(scopes).to include("mcp:atomspace:read", "mcp:atomspace:admin")
      expect(scopes).not_to include("mcp:i3:read")
    end

    it "grants both independently when both lists name the user" do
      ENV["I3_READ_GRANTS"] = "user:Alice"
      ENV["ATOMSPACE_READ_GRANTS"] = "user:Alice"
      expect(described_class.scopes_for("user:Alice", user_card: user_card))
        .to contain_exactly("mcp:atomspace:read", "mcp:i3:read")
    end

    it "never mints any write scope" do
      ENV["I3_READ_GRANTS"] = "user:Alice"
      ENV["ATOMSPACE_ADMIN_GRANTS"] = "user:Alice"
      scopes = described_class.scopes_for("user:Alice", user_card: user_card)
      expect(scopes.grep(/write/)).to be_empty
    end
  end

  describe Atomspace::I3ReadPort do
    after { described_class.reset! }

    it "is NOT ready when unbound (fail closed)" do
      described_class.reset!
      result = described_class.readiness
      expect(result.ready?).to be(false)
      expect(result.reason).to eq("i3_read_port_unwired")
    end

    it "reports origin unavailable when unbound (never 'live')" do
      described_class.reset!
      expect(described_class.origin).to eq("unavailable")
    end

    it "raises NotWired for every read when unbound" do
      described_class.reset!
      expect { described_class.open(card_id: 1) }.to raise_error(described_class::NotWired)
      expect { described_class.neighbours(card_id: 1) }.to raise_error(described_class::NotWired)
      expect { described_class.resolve_backend_address(card_id: 1) }
        .to raise_error(described_class::NotWired)
    end

    it "treats a raising readiness probe as not-ready with a per-class reason" do
      impl = Object.new
      impl.define_singleton_method(:readiness) { raise ArgumentError, "nope" }
      described_class.bind!(impl)
      result = described_class.readiness
      expect(result.ready?).to be(false)
      expect(result.reason).to eq("i3_readiness_probe_error:ArgumentError")
    end

    it "treats a contract-violating readiness answer as not-ready" do
      impl = Object.new
      impl.define_singleton_method(:readiness) { :yes }
      described_class.bind!(impl)
      expect(described_class.readiness.reason).to eq("i3_readiness_contract_violation")
    end

    # TRUTHY-READINESS REGRESSION. Everything except `false` and `nil` is TRUTHY in Ruby, and
    # MirrorReadiness::Result#ready? (mirror_readiness.rb:33-35) returns the struct member
    # UNCOERCED. So a Result built with ready: "false" / ready: 0 answers respond_to?(:ready?)
    # happily and would sail through a shape-only check -- the port must reject the VALUE's type
    # too, or the controller's readiness gate opens on a malformed backend answer.
    [
      ["the STRING \"false\"", "false"],
      ["the INTEGER 0", 0],
      ["the STRING \"true\"", "true"],
      ["a non-empty String", "ready"],
      ["nil", nil]
    ].each do |label, value|
      it "treats a readiness verdict of #{label} as NOT ready (never truthy-green)" do
        impl = Object.new
        impl.define_singleton_method(:readiness) do
          Atomspace::MirrorReadiness::Result.new(ready: value, reason: "synthetic")
        end
        described_class.bind!(impl)

        result = described_class.readiness
        # Not ready, and specifically flagged as a contract violation rather than passed through.
        expect(result.ready?).to be(false)
        expect(result.reason).to eq("i3_readiness_contract_violation")
      end
    end

    # The same hazard via a bare duck-typed object (no Result struct involved).
    it "treats a duck-typed ready? returning a truthy non-boolean as NOT ready" do
      impl = Object.new
      impl.define_singleton_method(:readiness) do
        Object.new.tap { |o| o.define_singleton_method(:ready?) { "false" } }
      end
      described_class.bind!(impl)
      expect(described_class.readiness.ready?).to be(false)
      expect(described_class.readiness.reason).to eq("i3_readiness_contract_violation")
    end

    # The genuine green path must still pass unchanged: a real boolean true is honoured.
    it "passes through a real boolean-true readiness verdict" do
      impl = Object.new
      impl.define_singleton_method(:readiness) { Atomspace::MirrorReadiness::READY }
      described_class.bind!(impl)

      result = described_class.readiness
      expect(result.ready?).to be(true)
      # The controller's gate is a STRICT `== true` comparison, so prove the exact object type.
      expect(result.ready?).to be_a(TrueClass)
    end

    # And a legitimate boolean-false not-ready answer is passed through with ITS OWN reason,
    # not masked as a contract violation.
    it "passes through a boolean-false verdict with the implementation's own reason" do
      impl = Object.new
      impl.define_singleton_method(:readiness) do
        Atomspace::MirrorReadiness::Result.new(ready: false, reason: "store_head_unavailable")
      end
      described_class.bind!(impl)

      result = described_class.readiness
      expect(result.ready?).to be(false)
      expect(result.reason).to eq("store_head_unavailable")
    end
  end

  describe Atomspace::FixtureI3ReadPort do
    it "declares itself as fixture origin, never live" do
      expect(described_class.new.origin).to eq("fixture")
    end

    # Even the fixture path refuses to invent a digest for an unknown target.
    it "refuses an unknown address with backend_digest_unavailable rather than computing one" do
      expect { described_class.new.resolve_backend_address(card_id: 7) }
        .to raise_error(Atomspace::I3ReadPort::AddressUnavailable, "backend_digest_unavailable")
    end

    it "returns the supplied backend address verbatim" do
      port = described_class.new(addresses: { "7" => { "key" => "(k)", "digest" => "abc" } })
      expect(port.resolve_backend_address(card_id: 7)).to eq("key" => "(k)", "digest" => "abc")
    end

    # PORT RESULT SHAPE CONTRACT (the port-side half of the controller's render_card_scoped
    # validation). The controller now REJECTS a non-Array result as a typed backend failure
    # instead of mapping it to an empty 200, so the shape the fixture port answers with is
    # load-bearing: it must be an Array on every path, including the miss path. An empty Array is
    # a LEGITIMATE result (a card with no atoms), which is precisely why the controller cannot
    # treat emptiness as a failure signal -- the two must stay distinguishable.
    it "answers open with an Array on both the hit and the miss path" do
      port = described_class.new(open_entries: { "7" => [:atom] })
      expect(port.open(card_id: 7)).to be_a(Array)
      expect(port.open(card_id: 7)).to eq([:atom])
      # MISS: an empty Array, NOT nil -- nil is what the controller must now refuse.
      expect(port.open(card_id: 99)).to be_a(Array)
      expect(port.open(card_id: 99)).to eq([])
      expect(port.open(card_id: 99)).not_to be_nil
    end

    it "answers neighbours with an Array on the miss, bucket-filtered and limited paths" do
      port = described_class.new(neighbour_entries: {
        "7" => [{ "bucket" => "a" }, { "bucket" => "b" }]
      })
      expect(port.neighbours(card_id: 99)).to eq([])
      expect(port.neighbours(card_id: 7)).to be_a(Array)
      # A bucket that matches nothing yields an EMPTY ARRAY -- a real, successful empty result.
      expect(port.neighbours(card_id: 7, bucket: "zzz")).to eq([])
      expect(port.neighbours(card_id: 7, bucket: "a")).to eq([{ "bucket" => "a" }])
      expect(port.neighbours(card_id: 7, limit: 1)).to eq([{ "bucket" => "a" }])
    end

    # The address the port hands #lookup must be a Hash with STRING-typed key/digest -- the
    # controller's validated_address_fields now enforces exactly that and refuses 503
    # backend_digest_unavailable otherwise, so the fixture must not be the thing that produces a
    # wrongly-typed address.
    it "answers resolve_backend_address with String-typed key and digest" do
      port = described_class.new(addresses: { "7" => { "key" => "(k)", "digest" => "abc" } })
      address = port.resolve_backend_address(card_id: 7)
      expect(address).to be_a(Hash)
      expect(address["key"]).to be_a(String)
      expect(address["digest"]).to be_a(String)
    end
  end
end
