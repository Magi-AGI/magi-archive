# frozen_string_literal: true

require "ipaddr"

module Atomspace
  # ORIGINAL TRANSPORT EVIDENCE CAPTURE -- the middleware half of the fix for the
  # "protocol evidence checked after it has been overwritten" defect.
  #
  # THE DEFECT. `ActionDispatch::AssumeSSL` REWRITES the request's protocol evidence in place:
  # it sets `HTTPS=on`, `HTTP_X_FORWARDED_PROTO=https` and `rack.url_scheme=https` on the env
  # hash and then calls the next app. Every Rails-level hook a controller can use --
  # `before_action`, `prepend_around_action`, `request.ssl?`, `request.scheme`,
  # `request.headers["X-Forwarded-Proto"]` -- runs DOWNSTREAM of that rewrite, so by the time any
  # controller code executes, the evidence it would consult has ALREADY been replaced with the
  # constant "https". A `require_secure_transport!` before_action therefore cannot work: it
  # reads the rewrite, not the request. (Reviewer-asserted anchor:
  # actionpack .../action_dispatch/middleware/assume_ssl.rb:21 -- UNVERIFIED on this host,
  # actionpack is not resolvable here, so the LINE NUMBER is cited as asserted, not confirmed.
  # The REWRITE BEHAVIOUR itself is what this file is built against and is why the capture must
  # be upstream.)
  #
  # THE FIX. Capture the evidence BEFORE AssumeSSL can touch it, in a middleware inserted
  # upstream of it, and park it in a dedicated env key that nothing downstream writes. The gate
  # then reads the CAPTURE, never the live request.
  #
  # WHAT IS DELIBERATELY ABSENT: `request.socket_ssl?`. It is NOT a Rails API -- calling it
  # raises NoMethodError -- so any gate built on it would fail closed only by accident, via the
  # unexpected-error handler, on EVERY request including legitimate ones. It is not used here and
  # must not be reintroduced.
  #
  # NOT A SUBSTITUTE FOR INFRASTRUCTURE. This middleware records what the first hop CLAIMED and
  # who claimed it. It cannot make an untrustworthy hop trustworthy. See the ASSUME_SSL note in
  # config/application.rb: `assume_ssl` trusts the forwarded protocol UNCONDITIONALLY, so with a
  # directly-reachable origin an attacker speaking cleartext straight to the origin is treated as
  # HTTPS by Rails regardless of anything in this file. Closing that is a proxy/firewall change,
  # not a code change.
  class OriginalProtocolEvidence
    # The env key the gate reads. Namespaced ("i3.") so it cannot collide with a rack.* or
    # action_dispatch.* key, and written exactly once per request by this middleware.
    ENV_KEY = "i3.original_transport"

    # The CIDR allowlist env var. Comma/whitespace separated, e.g.
    #   I3_TRUSTED_PROXY_CIDRS="173.245.48.0/20,103.21.244.0/22,127.0.0.1/32"
    #
    # UNSET OR EMPTY == TRUST NOBODY. That is the fail-closed default and it is intentional: a
    # forwarded-protocol header is a CLAIM by whoever connected, and with no configured list
    # there is no basis on which to believe any claimant. Under that default a cleartext request
    # is REFUSED rather than quietly honoured.
    TRUSTED_PROXY_CIDRS_VAR = "I3_TRUSTED_PROXY_CIDRS"

    def initialize(app)
      @app = app
    end

    def call(env)
      # Written BEFORE @app.call, i.e. before AssumeSSL (which sits downstream of this
      # middleware) can rewrite anything. Order is the entire control.
      env[ENV_KEY] = capture(env)
      @app.call(env)
    end

    class << self
      # Parse the allowlist. Returns [] for unset/blank/garbage -- never nil, never a
      # trust-everything sentinel. A malformed entry is DROPPED (and logged) rather than
      # widening the list or aborting the request: one typo must not turn into "trust all".
      def trusted_cidrs(raw = ENV[TRUSTED_PROXY_CIDRS_VAR])
        raw.to_s.split(/[,\s]+/).reject(&:empty?).each_with_object([]) do |entry, acc|
          begin
            acc << IPAddr.new(entry)
          rescue StandardError => e
            log_warn("i3_trusted_proxy_cidr_invalid: #{entry.inspect} (#{e.class})")
          end
        end
      end

      # Is this remote address inside the allowlist? DEFAULT-DENY on an empty list, an
      # unparseable address, a v4/v6 family mismatch, or ANY exception at all.
      def trusted_remote?(remote_addr, cidrs = trusted_cidrs)
        return false if cidrs.empty?

        addr = normalize_addr(remote_addr)
        return false unless addr

        cidrs.any? do |cidr|
          begin
            cidr.include?(addr)
          rescue StandardError
            # IPAddr raises on family mismatch (v4 cidr vs v6 addr). Not a match, not a crash.
            false
          end
        end
      rescue StandardError => e
        log_warn("i3_trusted_proxy_check_failed: #{e.class}")
        false
      end

      # Strip an IPv6 zone index and an IPv4-mapped-IPv6 prefix so a proxy on 127.0.0.1 arriving
      # as "::ffff:127.0.0.1" still matches a 127.0.0.1/32 entry. Returns nil on anything
      # unparseable -- which the caller treats as untrusted.
      def normalize_addr(remote_addr)
        text = remote_addr.to_s.strip
        return nil if text.empty?

        text = text.split("%").first.to_s
        text = text.sub(/\A::ffff:/i, "") if text =~ /\A::ffff:\d{1,3}(\.\d{1,3}){3}\z/i
        IPAddr.new(text)
      rescue StandardError
        nil
      end

      def log_warn(message)
        if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
          Rails.logger.warn(message)
        end
      rescue StandardError
        nil
      end
    end

    private

    # The capture itself. FROZEN, and every value is a plain String/nil/boolean copy -- nothing
    # downstream (AssumeSSL included) can mutate what the gate will later read, and the gate
    # cannot accidentally hold a live reference into the env hash.
    #
    # FIRST HOP ONLY. `X-Forwarded-Proto` is an append-only list: "https, http" means the hop
    # nearest the client said https and a later hop said http. Only the FIRST element is the
    # claim made by the peer we are actually authenticating via remote_addr, so only the first
    # element is kept. Taking the last, or `include?("https")`, would let a downstream hop (or an
    # attacker appending a value) decide the answer.
    def capture(env)
      forwarded_raw = env["HTTP_X_FORWARDED_PROTO"]
      first_hop = forwarded_raw.to_s.split(",").first.to_s.strip.downcase
      remote_addr = env["REMOTE_ADDR"].to_s

      {
        captured: true,
        # The scheme Rack itself derived before any rewrite.
        url_scheme: env["rack.url_scheme"].to_s.downcase,
        # The raw header exactly as received, kept for the audit log (never for the decision).
        forwarded_proto_raw: forwarded_raw.nil? ? nil : forwarded_raw.to_s,
        # The decision input: the FIRST hop's claim, normalized.
        forwarded_proto_first_hop: first_hop.empty? ? nil : first_hop,
        # Rack's own HTTPS flag, pre-rewrite.
        https_env: env["HTTPS"].nil? ? nil : env["HTTPS"].to_s.downcase,
        # WHO made the claim. Without this the claim is unauthenticated and worthless.
        remote_addr: remote_addr.empty? ? nil : remote_addr,
        # Resolved HERE, at capture time, against the remote address as it actually arrived.
        remote_trusted: self.class.trusted_remote?(remote_addr)
      }.freeze
    rescue StandardError => e
      # A capture failure must not become an allow. Return a frozen NEGATIVE capture: the gate
      # sees secure? == false and refuses.
      self.class.log_warn("i3_transport_capture_failed: #{e.class}")
      { captured: false, error: e.class.name }.freeze
    end

    # THE DECISION, kept next to the capture so the two cannot drift apart. Pure function of the
    # captured hash -- it touches no ENV, no request, no global state -- so it is directly
    # testable without booting Rails.
    #
    # SECURE only when BOTH hold:
    #   (a) the transport was already TLS at the point we observed it
    #       (rack.url_scheme == "https", or HTTPS=on), OR a forwarded-proto first hop said
    #       "https"; AND
    #   (b) when relying on (b)'s forwarded claim, the peer that made it is inside
    #       I3_TRUSTED_PROXY_CIDRS.
    #
    # Direct TLS to this process needs no allowlist -- there is no claimant to authenticate, we
    # observed the TLS ourselves. A FORWARDED claim is only ever as good as the hop that made it.
    #
    # @param capture [Hash, nil] the frozen hash from ENV_KEY (nil when the middleware did not run)
    # @return [Boolean] true only on positive evidence of TLS; false on absence, forgery or error.
    def self.secure?(capture)
      return false unless capture.is_a?(Hash)
      return false unless capture[:captured]

      # (a) Observed directly by this process. No trust decision required.
      return true if capture[:url_scheme] == "https"
      return true if capture[:https_env] == "on"

      # (b) Claimed by a hop. Honour it ONLY from an allowlisted peer.
      return false unless capture[:forwarded_proto_first_hop] == "https"

      capture[:remote_trusted] ? true : false
    rescue StandardError
      # Default-deny on ANY exception, including a frozen/odd capture object.
      false
    end
  end
end
