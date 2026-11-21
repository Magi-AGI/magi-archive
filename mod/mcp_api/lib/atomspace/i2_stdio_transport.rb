# frozen_string_literal: true

require "json"
require_relative "errors"

module Atomspace
  # THE TRANSPORT SEAM to a Python I2 reader process, and the ONLY transport that is in scope.
  #
  # WHY LINE-DELIMITED JSON OVER STDIO, AND NOTHING ELSE. Every other candidate is either
  # unauthorized or prohibited, and the reasons are STORE's and the coordinator's, not this file's:
  #
  #   * NO SOCKET. STORE's own header: the I2 read slice is "Not exposed on any socket: privileged,
  #     identity-free, and not MCP REST" (i2_read.py:57-58). STORE handoff 022b Q12 CONFIRMED: "One
  #     process, no socket, NO user identity at the I2 call."
  #   * NO HTTP. `store_transport.py` is a T-RA1 `GET /status` only, and the sidecar's `POST /read`
  #     is explicitly NOT an I2 path (handoff 022b Q11). Exposing I2 publicly is PROHIBITED.
  #   * NO PRIVILEGED TRANSPORT OF ANY KIND IS AUTHORIZED YET (handoff 022b, "STILL OPEN":
  #     "authorizing ... the privileged I2 transport"). So this file does not CREATE an
  #     authorization; it specifies the narrowest possible one and refuses to act without an
  #     explicitly supplied channel.
  #
  # STDIO therefore: the channel exists only as long as a LOCAL OPERATOR's own child process, it
  # has no listening port, no URL, no origin, nothing to authenticate to and nothing a browser or
  # a remote caller can reach. It is the only shape that adds no attack surface.
  #
  # THE FRAME FORMAT, in one sentence: one request is ONE LINE of JSON on the child's stdin, one
  # response is ONE LINE of JSON on its stdout, matched by an echoed `id`, and stderr is NOT part
  # of the protocol (it is the operator's log). The full contract is in the class docs below and
  # restated verbatim in the handoff packet for STORE.
  #
  # IDENTITY IS ABSENT BY CONSTRUCTION. A request frame has exactly five permitted keys and NONE
  # of them can carry a principal: STORE Q12 is CONFIRMED that there is no identity at the I2 call
  # and the ACL stays on the VIEW/deck side. `REQUEST_KEYS` is frozen and `write_request!` refuses
  # any key outside it, so an `account`, `token`, `bearer`, `cookie` or `user` field cannot be
  # added by accident at a call site -- it fails loudly instead.
  module I2StdioTransport
    # Raised when the channel itself fails: closed pipe, dead child, unreadable line, timeout.
    # DISTINCT from I2Envelope::ContractViolation (a well-delivered but malformed answer) because
    # the two need different operator responses -- restart the process vs fix the server.
    class ChannelError < Atomspace::Error; end

    # Raised when the child did not answer within the deadline. A subclass of ChannelError so a
    # caller that does not care gets the same fail-closed behaviour, and one that does can name it.
    class Timeout < ChannelError; end

    # Protocol version. Sent on every request and REQUIRED to match on every response, so a
    # mismatched server is refused at the first frame rather than misread at the tenth.
    PROTOCOL_VERSION = 1

    # The ONLY keys a request frame may carry. Enforced, not documented.
    #   v    -- PROTOCOL_VERSION
    #   id   -- an opaque correlation string chosen by VIEW; echoed verbatim
    #   op   -- the I2 operation id ("I2-01".."I2-10")
    #   args -- the operation's own arguments, a mapping; {} when it takes none
    #   deadline-ms -- advisory: the budget VIEW will wait. The child MAY use it; VIEW enforces
    #                  its own regardless, because a hung child cannot be trusted to self-limit.
    REQUEST_KEYS = %w[v id op args deadline-ms].freeze

    # The keys a response frame may carry. A frame with an unexpected key is refused: an extra
    # field means the two sides disagree about the contract.
    #   v, id    -- echoed
    #   ok       -- true for an answered operation, false for a refusal/error
    #   envelope -- the four-field I2 envelope (validated by I2Envelope). Present iff ok.
    #   payload  -- the operation's own result mapping. Present iff ok.
    #   error    -- {"kind", "op", "reason"}. Present iff NOT ok.
    RESPONSE_KEYS = %w[v id ok envelope payload error].freeze

    # Error `kind`s the server may send. Each maps to a DISTINCT VIEW-side condition, which is the
    # whole point of enumerating them: "the slice refuses this operation" and "the reader crashed"
    # must not collapse into one reason string.
    #   i2-refused            -- STORE's own I2Refused (i2_read.py:106-111): an unsupported
    #                            operation or input. Includes every non-empty narrowing, which is
    #                            refused BEFORE readiness (handoff 022b §3).
    #   unresolved-config     -- STORE's UnresolvedConfiguration (i2_read.py:98-103).
    #   capability-missing    -- a field with NO SOURCE: `versions.runtime` (handoff 022b Q3 = NO)
    #                            and the O23 health block (Q1 = NO). NEVER a fabricated value.
    #   server-error          -- anything else the server failed on, named but not detailed.
    ERROR_KINDS = %w[i2-refused unresolved-config capability-missing server-error].freeze

    # Key names that would carry a PRINCIPAL. The I2 call has no identity (STORE Q12), so none of
    # these may appear in a request frame AT ANY DEPTH.
    #
    # WHY DEPTH MATTERS. `REQUEST_KEYS` constrains only the TOP level, and `args` is an
    # unrestricted mapping by design (each operation owns its own argument shape). So a nested
    # `args: {participant: {..., "token" => "..."}}` would serialise cleanly even though the top
    # level is spotless -- the frame would be "identity-free" by the letter of the check and carry
    # a credential in fact. Checking recursively closes that, and it closes it HERE, before the
    # bytes exist, rather than hoping the server rejects them.
    #
    # Compared case-insensitively and after stripping `-`/`_`, so `Authorization`, `auth_token`
    # and `X-API-KEY` are all caught rather than only their exact spellings.
    # `authtoken` is listed EXPLICITLY. The comment above has always named `auth_token` as a
    # caught spelling, but normalisation maps it to `authtoken`, and membership is tested against
    # the NORMALISED form -- so until this entry existed the documented example was the one alias
    # that got through. `auth` and `token` are each present, but neither is a substring match:
    # `identity_key?` compares whole normalised keys, so `auth_token` matched nothing.
    FORBIDDEN_IDENTITY_KEYS = %w[
      account token bearer cookie user principal session authorization auth authtoken credential
      password secret apikey xapikey accesstoken refreshtoken identity actor subject login
      username userid accountid accountname sessionid sessiontoken csrftoken jwt oauth
      privatekey signingkey signature assertion samlresponse idtoken clientsecret
    ].freeze

    class << self
      # Normalise a key for identity comparison: lowercase, no separators.
      def identity_key?(key)
        normalised = key.to_s.downcase.gsub(/[-_\s]/, "")
        return false if normalised.empty?

        FORBIDDEN_IDENTITY_KEYS.include?(normalised)
      end

      # Walk a request's arguments and raise on any identity-shaped key at ANY depth. Hashes and
      # Arrays are both descended, because an identity could hide inside a list of mappings.
      def assert_identity_free!(value, path = "args")
        case value
        when Hash
          value.each do |k, v|
            if identity_key?(k)
              raise ChannelError,
                    "request args carry a forbidden identity-shaped key at #{path}.#{k}"
            end
            assert_identity_free!(v, "#{path}.#{k}")
          end
        when Array
          value.each_with_index { |v, i| assert_identity_free!(v, "#{path}[#{i}]") }
        end
        value
      end
    end

    class << self
      # Serialise and write ONE request line.
      #
      # @param writer [#puts, #flush] an injected IO-like sink. Duck-typed on purpose: the specs
      #   drive a StringIO, the operator drives a child's stdin, and this module can tell no
      #   difference -- which is exactly why it constructs neither.
      def write_request!(writer, id:, op:, args: {}, deadline_ms: nil)
        frame = { "v" => PROTOCOL_VERSION, "id" => id.to_s, "op" => op.to_s, "args" => args }
        frame["deadline-ms"] = deadline_ms if deadline_ms

        stray = frame.keys - REQUEST_KEYS
        # Unreachable from this method's own body -- which is the point. It is a STANDING ASSERTION
        # that no future edit smuggles an identity field into a frame, and a spec drives it
        # directly.
        raise ChannelError, "request frame carries forbidden keys: #{stray.sort.join(',')}" unless stray.empty?
        unless args.is_a?(Hash)
          raise ChannelError, "request args must be a mapping, got #{args.class}"
        end

        # NO IDENTITY AT ANY DEPTH. The top-level key check above cannot see inside `args`; this
        # does. See FORBIDDEN_IDENTITY_KEYS.
        assert_identity_free!(args)

        line = JSON.generate(frame)
        if line.include?("\n")
          # JSON.generate does not emit raw newlines, so this cannot normally trigger; asserted
          # anyway because the framing is LINE-delimited and a smuggled newline would desynchronise
          # the stream -- a silent correlation failure is far worse than a refusal.
          raise ChannelError, "a request line must not contain a newline"
        end

        writer.puts(line)
        writer.flush if writer.respond_to?(:flush)
        line
      rescue IOError, Errno::EPIPE => e
        raise ChannelError, "the reader process's input channel is closed (#{e.class})"
      end

      # Read ONE response line and return it parsed, with its FRAME-LEVEL shape checked. The
      # ENVELOPE's contents are NOT checked here -- that is I2Envelope's single responsibility.
      #
      # @param reader [#gets] an injected IO-like source.
      # @param expect_id [String] the correlation id. A mismatch is a ChannelError, never a
      #   tolerated skip: silently discarding an unmatched line would let a stale answer be read as
      #   the answer to the current question.
      def read_response!(reader, expect_id:)
        line = reader.gets
        # EOF. The child died, closed its stdout, or was never started. Fail closed.
        raise ChannelError, "the reader process closed its output channel without answering" if line.nil?

        frame = begin
          JSON.parse(line)
        rescue JSON::ParserError => e
          raise ChannelError, "the reader process emitted a line that is not JSON (#{e.class})"
        end

        raise ChannelError, "a response frame must be a JSON object, got #{frame.class}" unless frame.is_a?(Hash)

        extra = frame.keys - RESPONSE_KEYS
        raise ChannelError, "response frame carries unexpected keys: #{extra.sort.join(',')}" unless extra.empty?

        unless frame["v"] == PROTOCOL_VERSION
          raise ChannelError,
                "the reader process speaks protocol #{frame['v'].inspect}, not #{PROTOCOL_VERSION}"
        end

        unless frame["id"] == expect_id
          raise ChannelError,
                "response id #{frame['id'].inspect} does not match request #{expect_id.inspect}"
        end

        ok = frame["ok"]
        # STRICT BOOLEAN. `ok: "false"` and `ok: 0` are TRUTHY in Ruby, so a truthiness test here
        # would read a REFUSAL as an answer -- the same class of defect i3_read_port.rb:68-73
        # already closed for readiness. Only a real boolean is accepted.
        unless [true, false].include?(ok)
          raise ChannelError, "response `ok` must be a boolean, got #{ok.inspect}"
        end

        frame
      rescue IOError => e
        raise ChannelError, "the reader process's output channel failed (#{e.class})"
      end
    end

    # ---------------------------------------------------------------------------------------------
    # THE EXPLICIT, LOCAL-ONLY SPAWN HELPER.
    #
    # It is a SEPARATE class from the client for one reason: the client must be constructible with
    # NO ability to start a process. Keeping the spawn here means a spec, and a production boot
    # that has no server to run, can build and exercise the client over a pair of pipes without
    # this code ever loading `open3`.
    #
    # EVERY BOUNDARY THIS RESPECTS, stated as what it will not do:
    #
    #   * It NEVER runs at require time. Nothing here executes on load; `start!` is a method a
    #     local operator calls.
    #   * It NEVER autoloads and never self-installs. There is no initializer, no Railtie, no
    #     `config.after_initialize`, and nothing writes to Rails config.
    #   * It NEVER discovers its interpreter or script. Both paths are REQUIRED arguments supplied
      #   from the operator's own configuration. There is no PATH search, no default, no
    #     `which python`, no bundled script guess -- an unset path is an error, not a licence to
    #     guess (the same discipline i2_binding.py applies to SIDECAR_PATH_ENV).
    #   * It NEVER passes a credential. The child's argv and environment are built from the two
    #     explicit paths plus the sidecar root; there is no token, key, cookie or password
    #     anywhere, because the I2 call carries no identity (STORE Q12).
    #   * It NEVER installs anything. No pip, no gem, no network.
    # ---------------------------------------------------------------------------------------------
    class Spawn
      # @return [IO] the child's stdin (the `writer` a client wants)
      # @return [IO] the child's stdout (the `reader` a client wants)
      attr_reader :writer, :reader, :pid

      # @param interpreter [String] an ABSOLUTE path to the Python interpreter. Required.
      # @param script [String] an ABSOLUTE path to the STDIO server script. Required.
      # @param sidecar_path [String] the directory CONTAINING `atomspace_mirror_sidecar/`.
      #   Required: the server resolves STORE's modules from it, exactly as i2_binding.py does
      #   from AV_STORE_SIDECAR_PATH. Passed in the child's env, never guessed.
      # @param config [Hash] the I2 ceilings. NO DEFAULTS: I2Config has none
      #   (i2_read.py:120 "Every value is required; there is no default anywhere"), so neither
      #   does this. The operator states them.
      def initialize(interpreter:, script:, sidecar_path:, config:)
        @interpreter = require_absolute!(interpreter, "interpreter")
        @script = require_absolute!(script, "script")
        @sidecar_path = require_absolute!(sidecar_path, "sidecar_path")
        raise Atomspace::ServiceUnavailable, "config must be a mapping of I2 ceilings" unless config.is_a?(Hash)

        @config = config
        @writer = @reader = @pid = nil
      end

      # The child's environment, ENTIRE. Spawned with `unsetenv_others: true`, so this hash is not
      # merged into the parent's environment -- it REPLACES it, and the child sees exactly these
      # keys and nothing else.
      #
      # WHY REPLACEMENT AND NOT MERGE. A merge (the default) leaves every parent variable readable
      # by the child: a signing key, a bearer token, a DATABASE_URL, an AWS credential, a session
      # secret. This class's own boundary above says "It NEVER passes a credential", and under a
      # merge that claim was false -- the child inherited the whole process environment, so passing
      # no credential in argv achieved nothing. Replacement makes the claim true by construction.
      #
      # WHY EXACTLY THESE THREE, determined empirically on this host and not assumed. With
      # `unsetenv_others: true` and only these three entries, Python 3.12.4 starts, imports
      # `hyperon` 0.2.10 and imports `atomspace_mirror_sidecar.i2_read` successfully -- verified by
      # spawning it. Neither PATH nor SystemRoot/SYSTEMROOT is required: the interpreter is invoked
      # by ABSOLUTE path (so no PATH search happens) and CPython needs no PATH entry to initialise.
      # Nothing is allowlisted "just in case": an entry that is not demonstrably needed is a
      # secret-sized hole for no benefit.
      #
      #   AV_STORE_SIDECAR_PATH -- where the child resolves STORE's modules from (i2_binding.py's
      #                            own contract). The operator's explicit path, never guessed.
      #   AV_I2_STDIO_CONFIG    -- the I2 ceilings, which have no defaults (i2_read.py:120).
      #   PYTHONUNBUFFERED      -- line framing depends on the child not buffering its stdout.
      #
      # NONE of the three can carry an identity: they are two paths and a ceiling mapping, which is
      # the same reason REQUEST_KEYS cannot express a principal (STORE Q12).
      def child_env
        { "AV_STORE_SIDECAR_PATH" => @sidecar_path,
          "AV_I2_STDIO_CONFIG" => JSON.generate(@config),
          "PYTHONUNBUFFERED" => "1" }
      end

      # How long `stop!` waits for a child to exit on its own before escalating. A wedged child must
      # not be able to hang shutdown (or the documented rollback), so the wait is bounded.
      STOP_GRACE_SECONDS = 2.0

      # Start the child. Separate from #initialize so building the object is side-effect free and a
      # caller can inspect it (and a spec can construct it) without launching anything.
      #
      # @return [self]
      def start!
        require "open3"   # required HERE, not at file scope: a client that never spawns never
                          # loads a process-spawning library.
        raise Atomspace::ServiceUnavailable, "this spawn already started a process" if @pid

        # `unsetenv_others: true` is a Process.spawn option, and Open3.popen3 forwards it: popen3
        # pops a trailing Hash as its options hash (open3.rb:218-226 `if Hash === cmd.last then
        # opts = cmd.pop.dup`), adds its own :in/:out/:err redirections, and passes the result to
        # Process.spawn via popen_run -- while a LEADING Hash stays in `cmd` and is taken by spawn
        # as the env. So env and options are distinct positions and both arrive intact. Verified on
        # this host (Ruby 3.4.7): a sentinel secret planted in the parent env is visible to the
        # child WITHOUT this option and absent WITH it.
        stdin, stdout, stderr, wait = Open3.popen3(
          child_env, @interpreter, @script, unsetenv_others: true
        )
        stdin.sync = true
        @writer, @reader, @stderr, @wait = stdin, stdout, stderr, wait
        @pid = wait[:pid]
        self
      end

      # Stop the child and close the pipes. Idempotent.
      #
      # BOUNDED, IN THREE ESCALATING STEPS. Closing the child's stdin signals EOF, which is how the
      # server loop ends cleanly (`for line in stdin` returns). A child that is WEDGED -- stuck in
      # a native call, ignoring EOF, or blocked writing to a full stdout -- will never exit, so an
      # unbounded `@wait.join` would hang the caller forever, taking the documented rollback with
      # it. So: close the pipes, wait STOP_GRACE_SECONDS, then TERM, then KILL, and never block
      # past the budget. A shutdown path must always terminate.
      #
      # AND IT ONLY CLAIMS WHAT IT ESTABLISHED. The bound is not the whole requirement: a bounded
      # stop that cannot tell "the child is confirmed gone" from "I ran out of budget" lets a
      # caller treat an ORPHANED child as a completed shutdown -- so a rollback reports done while
      # a process still holds the AtomSpace open. Three leaks made that possible and all three are
      # closed here:
      #
      #   * `join_with_timeout` answered TRUE when the join itself RAISED, so a thread error read
      #     as a reaped child and could skip TERM/KILL entirely. It now reports the raise as
      #     UNCONFIRMED and escalation proceeds.
      #   * `signal_child` swallowed every failure, so an EPERM or an unsupported signal was
      #     indistinguishable from a delivered one. It now RETURNS whether delivery happened (and
      #     treats ESRCH as evidence the child is already gone).
      #   * the final wait's result was DISCARDED, so `stop!` returned `self` either way. It now
      #     returns a verdict.
      #
      # OWNERSHIP IS RETAINED ON AN UNCONFIRMED OUTCOME. `@pid`/`@wait` are cleared only when the
      # exit is confirmed; if it is not, the handles stay so a caller (or a later `stop!`) can
      # still see and re-attempt the child rather than losing the only reference to it.
      #
      # TRIGGER SEMANTICS ARE UNCHANGED. `stop!` is an EXPLICIT owner-initiated shutdown and the
      # only thing that kills a child. Nothing here adds an automatic, timer-driven or
      # error-driven kill path, so a child still serving another caller is never touched.
      #
      # @return [Symbol] `:confirmed` when the child's exit is established, otherwise
      #   `:unconfirmed`. Never raises on the shutdown path; `stop_confirmed!` is the variant for
      #   a caller that wants an unconfirmed shutdown to be an exception.
      def stop!
        # `Errno::EPIPE` IS RESCUED ALONGSIDE `IOError`, AND THAT IS NOT REDUNDANT. `Errno::EPIPE`
        # descends from `SystemCallError`, NOT from `IOError`, so an `IOError`-only rescue does not
        # catch it -- which is exactly how a broken pipe escaped this loop and made `stop!` raise,
        # contradicting the "never raises on the shutdown path" promise in this method's own
        # @return tag. It is reached whenever the child is ALREADY DEAD and a write has broken the
        # pipe: closing the write end of a pipe with no reader fails that way. `write_line` already
        # pairs the two for the same reason (`rescue IOError, Errno::EPIPE`); this is that pairing
        # on the close path.
        #
        # THE RESCUE STAYS NARROW ON PURPOSE. It names two classes and no more: not
        # `SystemCallError`, not `StandardError`, not a bare `rescue nil`. A broken or
        # already-closed pipe is the one failure that is MEANINGLESS here -- the pipe is being
        # discarded and the EOF it would have signalled is already a fact once the child is gone.
        # Any OTHER failure (EACCES, a RuntimeError from an injected IO, a bug in this class) still
        # propagates, because swallowing it would hide a real defect behind a shutdown path.
        [@writer, @reader, @stderr].each do |io|
          io&.close
        rescue IOError, Errno::EPIPE
          nil
        end

        pid = @pid
        # NOTHING TO STOP is a confirmed outcome, not a pretended one: a Spawn that never started,
        # or whose child was already confirmed gone by an earlier call, has no live child. This is
        # what makes the method idempotent AND keeps the second call honest.
        if pid.nil? && @wait.nil?
          @writer = @reader = @stderr = nil
          return :confirmed
        end

        outcome = join_with_timeout(STOP_GRACE_SECONDS)

        unless outcome == :exited
          delivered = signal_child(pid, "TERM")
          # `:gone` means the signal found no such process -- the child is already dead, which is
          # exactly the fact this method is trying to establish.
          outcome = delivered == :gone ? :exited : join_with_timeout(STOP_GRACE_SECONDS)
        end

        unless outcome == :exited
          delivered = signal_child(pid, "KILL")
          # The waiter THREAD may be abandoned if even KILL does not land within the budget: it is
          # a waiter, not the child, so leaving it unjoined cannot keep the process alive, and
          # blocking here is the one thing this method must never do. But abandoning the thread is
          # NOT evidence of exit, so the verdict below records that.
          outcome = delivered == :gone ? :exited : join_with_timeout(STOP_GRACE_SECONDS)
        end

        if outcome == :exited
          @wait = nil
          @pid = nil
          @writer = @reader = @stderr = nil
          :confirmed
        else
          # OWNERSHIP RETAINED on purpose -- see the note above. The caller is told plainly.
          :unconfirmed
        end
      end

      # `stop!` for a caller that must not proceed on an unconfirmed shutdown (a rollback, say).
      # Raises rather than letting an orphan read as a completed stop.
      #
      # @return [Symbol] :confirmed
      # @raise [Atomspace::ServiceUnavailable] when the child's exit could not be established.
      def stop_confirmed!
        verdict = stop!
        return verdict if verdict == :confirmed

        raise Atomspace::ServiceUnavailable,
              "the reader child's exit could not be confirmed within the shutdown budget " \
              "(pid=#{@pid.inspect}); the process may still be running and this Spawn still owns it"
      end

      private

      # Join the waiter thread with a bound.
      #
      # @return [Symbol] `:exited` ONLY when the thread actually finished within the bound (which
      #   is what reaping the child looks like), `:timeout` when the bound elapsed, and
      #   `:unknown` when the join itself raised.
      #
      # `:unknown` IS NOT SUCCESS. The previous version rescued and returned true here, reasoning
      # that "the child is gone either way" -- but a raise from `join` establishes nothing about
      # the CHILD, only about the waiter thread, and answering true let `stop!` skip the TERM and
      # KILL that would have made the claim real. Reporting it as unconfirmed costs one more
      # bounded wait and never asserts a death that was not observed.
      def join_with_timeout(seconds)
        return :exited unless @wait.respond_to?(:join)

        @wait.join(seconds).nil? ? :timeout : :exited
      rescue StandardError
        :unknown
      end

      # Signal the child and REPORT what happened, rather than swallowing it.
      #
      # @return [Symbol] `:gone` when the OS says there is no such process (ESRCH -- the child is
      #   already dead, which is positive evidence of exit), `:delivered` when the signal was
      #   accepted, and `:failed` when it could not be delivered (EPERM, an unsupported signal on
      #   this platform, a bad pid). A `:failed` must never be read as a stopped child: the
      #   previous version returned nil for all three, so a permission denial looked exactly like
      #   a successful terminate.
      #
      # It still does not RAISE: a stop path must terminate. It just stops lying about the result.
      def signal_child(pid, signal)
        return :failed unless pid

        Process.kill(signal, pid)
        :delivered
      rescue Errno::ESRCH
        :gone
      rescue Errno::EPERM, Errno::EINVAL, ArgumentError, NotImplementedError, RangeError,
             StandardError
        :failed
      end

      public

      # The child's stderr, for the OPERATOR's log. Deliberately not part of the protocol: a
      # server that signals a refusal on stderr instead of in an error frame would be invisible to
      # the client, so the client never reads this.
      def stderr_contents
        return "" unless @stderr

        @stderr.read_nonblock(65_536)
      rescue IO::WaitReadable, EOFError, IOError
        ""
      end

      private

      def require_absolute!(value, name)
        unless value.is_a?(String) && !value.strip.empty?
          raise Atomspace::ServiceUnavailable,
                "#{name} must be an explicit path supplied from configuration; there is no default " \
                "and no discovery"
        end
        # An absolute path only. A relative path would resolve against whatever cwd the boot
        # happened to have, which is not configuration.
        unless value.start_with?("/") || value.match?(/\A[A-Za-z]:[\\\/]/)
          raise Atomspace::ServiceUnavailable, "#{name} must be an absolute path, got #{value.inspect}"
        end

        value
      end
    end
  end
end
