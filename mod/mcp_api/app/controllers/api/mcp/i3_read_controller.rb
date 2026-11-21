# frozen_string_literal: true

# `CGI.unescape` percent-decodes the RAW participant value EXACTLY ONCE (see
# #resolve_participant_reference!). Required explicitly rather than leaned on: this file is
# `require`d by routes.rb at boot, before most of the stack is up.
require "cgi"

require_relative "../../../../lib/atomspace/errors"
require_relative "../../../../lib/atomspace/read_client"
require_relative "../../../../lib/atomspace/mirror_readiness"
require_relative "../../../../lib/atomspace/i3_read_port"
require_relative "../../../../lib/atomspace/authorized_card_identity"
require_relative "../../../../lib/atomspace/caller_scoped_card_authorization"
require_relative "../../../../lib/atomspace/observability"
# The ORIGINAL-TRANSPORT-EVIDENCE middleware, required for its ENV_KEY constant and its pure
# `.secure?` decision. Required here for the same reason as the lines above: mod lib is not
# autoloaded and routes.rb requires this controller at boot, so the constant must already exist.
require_relative "../../../../lib/atomspace/original_protocol_evidence"
require_relative "../../../../lib/mcp_api/atomspace_grants"
# Decko's routes.rb `require`s controllers at boot, BEFORE the mod's concerns autoload resolves;
# load the concern explicitly so `include AtomspaceReadFilter` can't NameError (same reason as
# atomspace_mirror_controller.rb:8-10).
require_relative "../../concerns/atomspace_read_filter"

module Api
  module Mcp
    # VIEW's I3 read surface: a MINIMAL REAL-CARD PATH (lookup / open / neighbours) over the STORE's
    # I2 slice, mounted in the deck and gated by the NAMESPACED mcp:i3:read scope.
    #
    # SECURITY MODEL (every clause here is load-bearing):
    #
    #   * require_user_principal! RUNS FIRST, before the scope gate and before readiness. It refuses
    #     a service-account principal in BOTH of the two ways one can arrive:
    #       (1) MISMATCHED FALLBACK. BaseController#find_mcp_account (base_controller.rb:81-91) falls
    #           back to the SERVICE ACCOUNTS MCP_USER_NAME / MCP_GM_NAME / MCP_ADMIN_NAME when the
    #           token's subject does not resolve. The resolved account's id then differs from the
    #           token subject's own, which the id comparison below rejects.
    #       (2) NAMED DIRECTLY AS THE SUBJECT. A token whose sub is literally
    #           "user:<service account name>" takes find_mcp_account's DIRECT-SUBJECT branch
    #           (base_controller.rb:73-79, which RETURNS at :78), so the fallback is never entered
    #           and the ids MATCH -- the id comparison alone would admit it. The service accounts are
    #           real type:User cards, so they are excluded BY CANONICAL IDENTITY as well --
    #           service_account?, which compares PERSISTED CARD IDS, not name strings, because
    #           Decko canonicalizes separators and case (cardname.rb:101-116) so "mcp_admin" and
    #           "mcp-admin" are ONE card and a string comparison would miss the alias.
    #     Either way an administrative credential cannot stand in for a real user, and neither check
    #     touches data before refusing.
    #
    #   * Authority is NEVER keyed off payload["role"]. On a key token the role is SELF-ASSERTED
    #     (auth_controller.rb:243-248), so role plays no part in any decision below.
    #
    #   * NO Card::Auth.as_bot ANYWHERE on this request path. A bot-scoped lookup inside a user
    #     request bypasses the caller's ACLs (the cards_controller.rb:586/:592 anti-pattern). Every
    #     card touch happens under Card::Auth.as(@current_mcp_account.name) via AtomspaceReadFilter.
    #
    #   * Fail CLOSED on missing readiness, metadata or permissions. No handler fabricates an epoch,
    #     position, read-at, coverage, health or configuration value to be able to answer.
    #
    # NOT IMPLEMENTED ON PURPOSE (O25 is UNAUTHORIZED): no focus-request behaviour, no Form R/P, no
    # conditional option A, and no new wire vocabulary beyond lookup / open / neighbours. This
    # surface also never consumes its own I3 endpoint recursively, never exposes the privileged I2
    # surface publicly, and never substitutes MCP card JSON for a backend read.
    #
    # ===========================================================================================
    # SAME-ORIGIN DECKO-SESSION AUTHENTICATION (the browser path)
    # ===========================================================================================
    #
    # WHY IT EXISTS. The browser client is served from the SAME ORIGIN as this deck, so it already
    # holds a Decko session cookie. The alternative -- handing the browser an MCP bearer/JWT --
    # would mean shipping a SECRET to a context that cannot keep one. This path therefore carries
    # NO TOKEN AND NO SECRET TO THE BROWSER AT ALL: the only credential is the already-existing
    # same-origin session cookie, which the user agent attaches automatically.
    #
    # HOW THE PRINCIPAL IS ESTABLISHED, verified against the REAL card gem source (the decko
    # monorepo checkout at E:/GitHub/Magi-AGI/decko, card/VERSION 0.19.1 -> card gem 1.109.1;
    # see the version note at #session_account below):
    #
    #   1. Decko's own controller does `Card::Env.reset self` in its `setup` before_action
    #      (decko/lib/card_controller/rest.rb:31-35), then `Card::Auth.signin_with(**authenticators)`
    #      in `authenticate` (rest.rb:37-39).
    #   2. With no token, `signin_with` falls through to `signin_with_session`
    #      (card/lib/card/auth/current.rb:50-56), which reads `session[session_user_key]`
    #      (current.rb:59-63) -- the SESSION-STORED card id.
    #   3. `session_user_key` is `:"user_#{Cardio.database.underscore}"` (current.rb:82-84), i.e.
    #      `user_magi_archive_production` for this deck (config/database.yml:9).
    #   4. That id is accepted ONLY if `card_id.card&.account?` (current.rb:61) -- `#card` is the
    #      Integer/Symbol core extension `Card[self]`
    #      (card/config/initializers/01_core_extensions/persistent_identifier.rb:6-8), and
    #      `account?` is true only for a real account holder
    #      (mod/account/set/abstract/account_holder.rb:11-13), false for Anonymous
    #      (mod/account/set/self/anonymous.rb:6-8).
    #   5. `Card::Auth.signin` then sets `current_id` (current.rb:36-41), and `signed_in?` is
    #      exactly `current_id != AnonymousID` (current.rb:45-47).
    #
    # THIS SURFACE DOES NOT RE-IMPLEMENT ANY OF THAT. It READS the already-established framework
    # state (`Card::Auth.signed_in?` / `Card::Auth.current_id` / `Card::Auth.current_card`) and
    # refuses when there is no signed-in account. It never writes the session, never calls
    # `signin`, and never derives an identity from anything the REQUEST asserted.
    #
    # IMPORTANT ORDERING CONSEQUENCE, and why #session_account re-establishes identity itself:
    # `Card::Env.session` is `request&.session` via `Env.controller`
    # (card/lib/card/env.rb:21-23, :25-29). `Api::Mcp::BaseController` is an
    # `ActionController::API` subclass and NOT Decko's `CardController`, so NOTHING in this
    # request has run `Card::Env.reset self` or `Card::Auth.signin_with`. The framework's session
    # ->account resolution is therefore invoked EXPLICITLY here, through the framework's OWN
    # methods, rather than assumed to have happened.
    #
    # ROLE IS READ FROM THE FRAMEWORK, NEVER FROM THE REQUEST. On the session path the role/scope
    # decision uses `Card::Auth.current_roles` (current.rb:28-33, which is
    # `Set::Self::Role.role_ids(current_id)`) -- persisted role membership. `payload["role"]` is
    # self-asserted on a key token (auth_controller.rb:243-248) and plays no part on either path.
    #
    # NO ELEVATION, SAME ACL. The session principal is fed to the SAME
    # `Atomspace::CallerScopedCardAuthorization` primitives and the SAME `AtomspaceReadFilter` as
    # the token principal, so every card touch still runs under `Card::Auth.as(account.name)` and
    # there is still NO `as_bot` anywhere on this path. The session path adds an AUTHENTICATION
    # mechanism only; it widens NO authorization.
    #
    # READ-ONLY AND CSRF-CORRECT. Every action here is a GET and mutates nothing. Rails'
    # `verified_request?` is `!protect_against_forgery? || request.get? || request.head? || ...`
    # (actionpack-7.2.2.2/lib/action_controller/metal/request_forgery_protection.rb:461-464), so a
    # GET is exempt from token verification by construction -- and in any case
    # `ActionController::API` does not include `RequestForgeryProtection` at all (its MODULES list,
    # actionpack .../action_controller/api.rb:115-146, omits both `Cookies` and
    # `RequestForgeryProtection`, which `ActionController::Base` includes at base.rb:288/:291).
    # Because the cookie is `SameSite=Lax` (config/initializers/session_store.rb:4,:10) and Lax
    # DOES attach on cross-site top-level GET navigation, this surface must never acquire a
    # state-changing action; it has none, and a read cannot be weaponised by a forged navigation
    # beyond what the user could already read themselves.
    class I3ReadController < BaseController
      include AtomspaceReadFilter

      # _meta for PRE-AUTHORIZATION refusals. Deliberately OMITS data_origin: the real i3_meta
      # carries the port's origin ("fixture"/"live"/"unavailable"), which is a backend signal, and
      # emitting it on a principal/scope denial would contradict the order-of-gates contract below
      # ("An unauthorized caller therefore never receives a readiness/backend signal"). Post-auth
      # responses keep the full i3_meta so the fixture-labelling guarantee is preserved.
      DENIED_META = { surface: "i3" }.freeze

      # _meta for the LAST-RESORT unexpected-error path. Separate constant from DENIED_META so
      # neither can be repurposed by accident, and CONSTANT for two independent reasons:
      #   (1) an exception can be raised BEFORE require_user_principal! has completed, so the
      #       handler must not consult the port -- calling i3_meta there would emit the backend's
      #       origin to a caller who was never authorized, recreating exactly the disclosure the
      #       DENIED_META split removed; and
      #   (2) if Atomspace::I3ReadPort.origin is ITSELF what raised, a handler that calls i3_meta
      #       re-enters the failing method and the fixed error response is never produced at all.
      # Nothing here is derived from the request, the exception or the backend.
      ERROR_META = { surface: "i3" }.freeze

      # THE PRE-AUTHENTICATION CONFIGURATION REFUSAL, and it gets its OWN exception class on purpose.
      #
      # `clear_mcp_state_after_request` is a `prepend_around_action` (below), so it wraps the WHOLE
      # action -- including the auth chain -- and its first statement,
      # `assert_single_threaded_identity!`, therefore runs BEFORE `require_user_principal!`. That
      # ordering is REQUIRED and is not the defect: `require_user_principal!` itself touches cards
      # under `Card::Auth`/`Card::Env`, which is precisely the module-level identity state the guard
      # exists to protect, so refusing before any card touch is the only correct place for it.
      #
      # The consequence is that this is the ONE refusal on this surface an ENTIRELY UNAUTHENTICATED
      # caller (no session, no token, bad token) can reach. So it MUST NOT be raised as an
      # `Atomspace::ServiceUnavailable`: that class is handled by `render_backend_unavailable` ->
      # `render_unavailable`, which (a) renders `_meta: i3_meta`, disclosing the backend's
      # `data_origin` ("live"/"fixture"/"unavailable"), and (b) fires a class-3 backend Observability
      # alert attributable to that caller. Both contradict the order-of-gates contract below ("An
      # unauthorized caller therefore never receives a readiness/backend signal"), and the distinct
      # body also made a misconfigured server DISTINGUISHABLE from a normal 401.
      #
      # A dedicated class -- NOT a subclass of `Atomspace::Error`, so no `rescue_from` for a backend
      # condition can ever match it -- makes picking up the meta-bearing renderer IMPOSSIBLE rather
      # than merely discouraged. The explanation of what is misconfigured lives in the raised
      # message and the server-side log ONLY, never on the wire.
      class UnsupportedServerConfiguration < StandardError; end

      # The ENTIRE rendered body of that refusal. A frozen CONSTANT, like ERROR_META, so nothing
      # derived from the request, the configuration or the backend can be grown into it by accident,
      # and no request can mutate it. It reuses the EXISTING 503 wire vocabulary deliberately: a
      # misconfigured server must not be fingerprintable as a distinct response shape.
      CONFIG_REFUSAL_BODY = { error: "i3_backend_unavailable",
                              reason: "i3_backend_unavailable" }.freeze

      # ===========================================================================================
      # READINESS REASON CLASSIFICATION: which of the TWO no-state outcomes is TRUE of a failure.
      #
      # `k8-draft-2.md:486-487` enumerates them with DIFFERENT meanings, and reporting one as the
      # other is a false statement about the store:
      #   * `not ready`   -- "no published state can be read yet (bootstrap, rebuild)". THE STORE
      #                      ANSWERED, and what it answered is that it has no published state.
      #   * `unavailable` -- "the store could not be reached or could not answer". NOTHING WAS
      #                      LEARNED about the store's state.
      # See #readiness_outcome_for for the fail-closed default and the full argument.
      # ===========================================================================================

      # THE ONLY reasons on which STORE ITSELF reported on its own published state. Each is an
      # answer that CAME BACK FROM THE STORE, so `not ready` is a true statement:
      #   * `i2_store_not_ready` (`i2_reader_process_client.rb:113`) -- set at `:200-202` from
      #     `I2Envelope.not_ready?(envelope)`, i.e. STORE's OWN I2-01 envelope said `not ready`.
      #   * `i2_store_outcome_not_ok` (`:123`, set at `:226-229`) -- STORE answered coherently with
      #     a state-bearing envelope whose outcome is "ok, partial" / "unknown" / "reload": a real
      #     answer that is not a green light, but the store WAS reached and DID answer.
      #   * `i2_reader_refused_status` (`:117`, set at `:195-197`) -- STORE returned a well-formed
      #     I2-01 ERROR FRAME. It was reached and it answered; the answer was a refusal.
      #   * `i2_reader_schema_mismatch` (`:118`, set at `:207-210`) -- STORE answered and NAMED its
      #     schema; this deck cannot read that corpus. Again, reached and answered.
      #   * the `mirror_*` / `sidecar_*` verdicts from `mirror_readiness.rb:50-66`, for the case
      #     where a bound reader delegates to that predicate. Each is a PROBED, OBSERVED state --
      #     mirroring switched off, no completed bootstrap, a rebuild in progress, or a sidecar
      #     that ANSWERED with a card count below its bootstrap baseline. The probe got an answer;
      #     the answer is "there is no state you may read yet". `sidecar_unreachable` is NOT in this
      #     list -- it belongs with the unreachable class below, which is exactly the distinction
      #     this classification exists to make.
      READINESS_STORE_ANSWERED_REASONS = %w[
        i2_store_not_ready
        i2_reader_refused_status
        i2_reader_schema_mismatch
        mirroring_disabled
        mirror_tables_unavailable
        mirror_not_bootstrapped
        mirror_rebuild_in_progress
        sidecar_empty_post_restart
        sidecar_below_expected
      ].freeze

      # Reasons in which the store COULD NOT BE REACHED OR COULD NOT ANSWER, so `unavailable`
      # (`k8-draft-2.md:487`) is the true outcome. Listed EXPLICITLY -- rather than relied on via
      # the default -- so the mapping is auditable and a reviewer can see each one is accounted for:
      #   * `i3_read_port_unwired` (`i3_read_port.rb:44`, returned at `:72`) -- NO READER IS BOUND.
      #     No store was contacted at all, so nothing can be asserted about any store's state.
      #   * `i3_readiness_contract_violation` (`i3_read_port.rb:76`, `:83`) -- the bound impl's
      #     readiness answer was MALFORMED (missing `ready?`, or a non-boolean verdict). The impl
      #     "could not answer" in the contract's own words.
      #   * `i3_reader_declares_no_readiness` (`local_i3_read_binding.rb:74`) -- the bound reader
      #     cannot state readiness at all.
      #   * `i3_read_port_envelope_unsupported` (`i3_read_port.rb:54`) -- a bound impl that cannot
      #     carry STORE's envelope: a deployment mismatch, not a store statement.
      #   * `i2_reader_timeout` (`i2_reader_process_client.rb:115`, rescued at `:232-233`) -- the
      #     child DID NOT ANSWER IN TIME. Literally "could not answer".
      #   * `i2_reader_channel_unavailable` (`:114`, rescued at `:234-235`) -- the pipe is dead /
      #     EOF. Literally "could not be reached".
      #   * `i2_reader_contract_violation` (`:116`, rescued at `:236-237`) -- the frame was
      #     missing or unreadable, so no answer was obtained.
      #   * `sidecar_unreachable` (`mirror_readiness.rb:62`) -- the sidecar probe reported
      #     `reachable: false`. "Could not be reached" is this reason's literal content, so it is
      #     classified with the unreachable class and NOT with its `mirror_*` siblings above.
      #   * `i2_store_outcome_not_ok` (`i2_reader_process_client.rb:119`, REASON_DEGRADED_OUTCOME)
      #     -- the I2-01 envelope carried a STATE-BEARING outcome that is not a clean "ok":
      #     "ok, partial", "unknown" or "reload". The store ANSWERED, and what it answered is that
      #     a state EXISTS but is not a green light. Reporting that as `not ready` would assert
      #     "there is no published state", which is the one thing this answer disproves -- a false
      #     statement about the state. It is not `not ready`, and VIEW cannot read it, so the
      #     honest in-band answer is `unavailable`: "could not answer" the read as asked
      #     (`k8-draft-2.md:487`). This is a THIRD category -- answered, state-bearing, unusable --
      #     and it is classified here deliberately rather than collapsed into the no-state claim.
      READINESS_UNREACHABLE_REASONS = %w[
        i3_read_port_unwired
        i3_readiness_contract_violation
        i3_reader_declares_no_readiness
        i3_read_port_envelope_unsupported
        i2_reader_timeout
        i2_reader_channel_unavailable
        i2_reader_contract_violation
        sidecar_unreachable
        i2_store_outcome_not_ok
      ].freeze

      # `i3_read_port.rb:88` builds its reason by INTERPOLATING the exception class
      # (`"i3_readiness_probe_error:#{e.class}"`), so the full string is not enumerable. The probe
      # RAISED, which means no answer was obtained -> `unavailable`. Matched by prefix, and the
      # prefix includes the colon so only the generated form matches.
      READINESS_PROBE_ERROR_PREFIX = "i3_readiness_probe_error:"

      # Role keys that are VACUOUS as a session entitlement: every signed-in caller holds them (or
      # they are the framework's everyone-sets), so naming one in I3_SESSION_READ_ROLE would make
      # #session_role_entitled? always true and turn the gate into "any signed-in user".
      # Configuring one is treated as an operator error and REFUSED, not honoured.
      #
      # `anyone_signed_in` is unconditionally prepended to `Card::Auth.current_roles`
      # (card/lib/card/auth/current.rb:28-33). `all` / `anyone` are Decko's everyone-sets. Keys are
      # the canonical form produced by Cardname (cardname-0.19.1/lib/cardname.rb:72), which is what
      # #session_role_entitled? compares, so every separator/case alias of these names normalizes
      # into this list rather than slipping past it.
      VACUOUS_SESSION_ROLE_KEYS = %w[anyone_signed_in anyone all *all].freeze

      # Upper bound on the `participant` address parameter (see #require_subject_card_id!).
      # Decko's `cards.name` column is a varchar(255), so a name longer than this cannot name an
      # existing card and does not need to be fetched to be refused. The budget is the NAME limit
      # plus the 2-byte structural prefix (`~k` / `~d`), applied to the encoded value FIRST so an
      # overlong input is rejected before it is decoded or expanded.
      MAX_PARTICIPANT_BYTES = 257

      # BaseController clears the MCP thread flag and Card::Auth in an after_action, which Rails
      # SKIPS when a before_action halts. Every gate below can halt, so this must wrap the whole
      # chain (including BaseController's own filters) or identity teardown leaks.
      prepend_around_action :clear_mcp_state_after_request

      # ===========================================================================================
      # THE FILTER-CHAIN FIX: without this line the session path below is DEAD CODE over HTTP.
      # ===========================================================================================
      #
      # THE DEFECT IT CLOSES. BaseController declares
      # `before_action :authenticate_mcp_request!, unless: :auth_endpoint?` (base_controller.rb:11),
      # and `auth_endpoint?` is only true for the "auth"/"jwks" controllers
      # (base_controller.rb:28-30). For THIS controller `controller_name` is "i3_read", so the
      # Bearer gate RUNS -- and `authenticate_mcp_request!` renders 401 "Missing authorization
      # token" whenever `extract_token_from_header` yields nil (base_controller.rb:33-34), which it
      # does for ANY request whose Authorization header does not begin with "Bearer "
      # (base_controller.rb:52-56). A same-origin browser request carries NO Authorization header
      # at all, so it was refused by a PARENT filter registered BEFORE this subclass's
      # `before_action :require_user_principal!`. #require_session_principal! never executed in a
      # real request. (The standalone harness missed this because it drives the auth METHODS
      # directly and so never builds the callback chain.)
      #
      # WHY A CONDITIONAL SKIP AND NOT AN EDIT TO base_controller.rb. base_controller.rb is SHARED
      # by every MCP controller (auth, jwks, atomspace_mirror, ...). Widening `auth_endpoint?`, or
      # relaxing the Bearer gate there, would change the authentication posture of surfaces that
      # are not part of this slice. `skip_before_action` is scoped to THIS class instead -- see the
      # isolation proof below -- so the blast radius is exactly one controller.
      #
      # WHY THIS IS NOT A BYPASS, verified by EXECUTION against the installed
      # activesupport-7.2.2.2 / actionpack-7.2.2.2 (see
      # spec/mcp_api/i3_filter_chain_proof.rb):
      #
      #   1. `skip_before_action` is `skip_callback(:process_action, :before, name, options)`
      #      (actionpack .../abstract_controller/callbacks.rb:245-249). With an `:if` option,
      #      `skip_callback` does NOT delete the callback outright: it builds a replacement via
      #      `callback.merge_conditional_options(chain, if_option:, unless_option:)`, inserts it at
      #      `chain.index(callback)`, then deletes the original
      #      (activesupport .../active_support/callbacks.rb:799-804). So `if:` on a skip IS
      #      supported, and the callback KEEPS ITS ORIGINAL POSITION in the chain.
      #   2. `merge_conditional_options` appends our `if_option` to the callback's `:unless` list
      #      (callbacks.rb:257-267). The parent's filter therefore ends up as
      #      `unless: [:auth_endpoint?, :session_mode?]` -- i.e. the Bearer gate still RUNS for
      #      every request that is not in session mode. It is NOT removed and NOT reordered.
      #   3. NO WIDENING OF ANY OTHER CONTROLLER. `__update_callbacks` walks
      #      `self.descendants.prepend(self)` (callbacks.rb:686-691) -- this class and its
      #      DESCENDANTS only, never its ancestors -- and `set_callbacks` dups `__callbacks` before
      #      writing (callbacks.rb:936-941). BaseController's own chain, and every sibling
      #      subclass's, is left byte-identical. Proven by execution, not by reading.
      #   4. NO FALLBACK FROM A FAILED TOKEN. The skip is keyed on `session_mode?`, which is the
      #      TOTAL ABSENCE of an Authorization header. A request that PRESENTS a header -- valid,
      #      expired, forged, "Basic", lowercase "bearer", or blank -- is not in session mode, so
      #      the parent Bearer gate runs and refuses it AS A TOKEN. A bad token can never be
      #      downgraded to "whoever is signed in in that browser".
      #   5. NO ANONYMOUS SERVICE. Skipping the parent gate does not authenticate anybody; it only
      #      lets the chain reach `require_user_principal!` -> `require_session_principal!`, which
      #      REFUSES (401/403) unless the framework reports a real, signed-in, non-service
      #      type:User account. There is no anonymous-but-permissive read on either path.
      #   6. ORDER AND TEARDOWN SURVIVE. The replacement callback holds the parent's index, so the
      #      order is still [around teardown] -> set_mcp_thread_flag -> (Bearer gate) ->
      #      require_user_principal! -> require_i3_read_scope! -> require_i3_backend_ready!, and
      #      `prepend_around_action :clear_mcp_state_after_request` above still wraps ALL of it --
      #      including the parent filter in the branch where it is NOT skipped -- so Card::Env /
      #      Card::Auth identity cannot survive a request either way.
      #
      # FAILS LOUD IF THE PARENT RENAMES THE FILTER: `skip_callback` sets `options[:raise] = true`
      # by default (callbacks.rb:789) and raises ArgumentError when the named callback is not in
      # the chain (:795-797). If base_controller.rb ever drops or renames
      # `authenticate_mcp_request!`, THIS CLASS FAILS TO LOAD rather than silently serving
      # unauthenticated requests.
      #
      # SAFE TO EVALUATE THIS EARLY: `session_mode?` reads ONE request header and touches no
      # database, no session, no Card state and no ivar set by a later filter, so it is valid as a
      # condition on a callback that runs before any of this controller's own gates.
      skip_before_action :authenticate_mcp_request!, if: :session_mode?

      # ORDER IS THE CONTRACT: real-user principal, THEN scope, THEN readiness. An unauthorized
      # caller therefore never receives a readiness/backend signal.
      before_action :require_user_principal!
      before_action :require_i3_read_scope!
      before_action :require_i3_backend_ready!

      # UNEXPECTED-ERROR CONTAINMENT, and it MUST BE REGISTERED FIRST.
      #
      # ActiveSupport::Rescuable resolves handlers with `rescue_handlers.reverse_each.detect`, so
      # the LAST matching registration wins. Registering StandardError here -- BEFORE the four
      # specific handlers below -- therefore gives it the LOWEST precedence of the five, so
      # NotWired / AddressUnavailable / ServiceUnavailable / InvalidRequest keep their own typed
      # renders; and because a subclass's registrations come after the parent's, this one still
      # OVERRIDES BaseController's `rescue_from StandardError, with: :handle_error`
      # (base_controller.rb:15).
      #
      # WHY OVERRIDE IT: handle_error renders `details: { exception: <class>,
      # exception_message: exception.message }` (base_controller.rb:129-136). On this surface that
      # message is a DISCLOSURE CHANNEL -- it can carry card names, SQL fragments, file paths and
      # backend internals to a caller who may not read any of them, which would undo the
      # not-an-oracle property the rest of this controller is built around. base_controller.rb is
      # NOT modified; the containment is local to this surface.
      rescue_from StandardError, with: :render_unexpected_error

      rescue_from Atomspace::I3ReadPort::NotWired, with: :render_port_unwired
      rescue_from Atomspace::I3ReadPort::AddressUnavailable, with: :render_address_unavailable
      rescue_from Atomspace::ServiceUnavailable, with: :render_backend_unavailable
      rescue_from Atomspace::InvalidRequest, with: :render_invalid_request

      # Registered AFTER the StandardError catch-all above, so it takes precedence over it
      # (`rescue_handlers.reverse_each.detect`). Its own class AND its own handler: the whole point
      # is that this pre-authentication refusal cannot reach a meta-bearing renderer. See
      # UnsupportedServerConfiguration above.
      rescue_from UnsupportedServerConfiguration, with: :render_unsupported_configuration

      # --- I3 lookup: name -> {key, digest} -------------------------------------------------------
      #
      # TWO HALVES, deliberately unequal (be clear about which is which):
      #
      #   GENUINE (implemented here, really enforced): the NAME -> DECKO CARD resolution. Decko
      #   legitimately allows resolving a name to a card THE CALLER MAY READ, so it is done under the
      #   caller's own identity -- Card::Auth.as(account.name) inside readable_card_id_for_name, with
      #   AtomspaceReadFilter's default-deny (atomspace_read_filter.rb:26-30) rejecting nil / new /
      #   blank-read-rule cards BEFORE asking ok?(:read). A name the caller cannot read is reported
      #   as `unknown`, identically to a name that does not exist, so this endpoint is not a
      #   read-permission oracle.
      #
      #   UNFILLED BACKEND REQUEST (declared, never faked): the CARD -> {key, digest} resolution.
      #   The store has NO name->key or card_id->key resolver (zero grep hits across i2_read.py,
      #   record_store.py, reads.py, ipc.py; addresses are `{"key"=>text}` / `{"digest"=>hex}` --
      #   i2_read.py:474-482). And the digest MUST come from the backend's own participant head:
      #   VIEW is FORBIDDEN to compute one deck-side (adapter.py:1473-1476) because a deck-side
      #   digest is a DIFFERENT VALUE from the store's and would silently disagree with every other
      #   endpoint. So when the port is unwired this answers 503 backend_digest_unavailable. It does
      #   NOT compute a digest, and it does NOT downgrade the gap to `unknown` -- an unresolvable
      #   backend is reported as a backend condition, explicitly DISTINGUISHABLE from `unknown`.
      def lookup
        name = params[:name].to_s
        return render_bad_request("name_required") if name.strip.empty?

        identity = readable_identity_for_name(name)
        # THE LOOKUP-MISS RULE (K8 §5.5 :574, §5.3 :483). A name that does not resolve -- and a name
        # the caller may not read, which collapses to the SAME answer so this endpoint is not a
        # read-permission oracle -- is the outcome `unknown` with NO payload. It is an ANSWER, not a
        # backend condition and not a 503.
        return render_lookup_unknown unless identity

        reading = Atomspace::I3ReadPort.lookup_reading(card_id: identity.card_id)

        # STORE itself answered `unknown`: the card is readable and resolved deck-side, but its key
        # is not a participant of the published state. Rendered with STORE's OWN envelope -- its
        # real outcome and its real state triple -- never a locally-built one.
        if reading.address.nil?
          return render_i3(reading, payload: {})
        end

        key, digest = validated_address_fields(reading.address)
        # ==========================================================================================
        # NO `name` IS EMITTED, AND THAT IS THE HONEST ANSWER (resolution (b) of the two).
        # ==========================================================================================
        #
        # WHAT WAS HERE. `"name" => identity.canonical_name`. That value is DECKO's name:
        # `AuthorizedCardIdentity.from_card` sets `canonical_name: card.name.to_s`
        # (`authorized_card_identity.rb:58`). The Coordinator requirement is explicit that the
        # canonical resolved name must come from the STORE's resolved entry and never be echoed
        # from the request -- and by the same logic it may not be substituted from the
        # AUTHORIZATION identity either, because Decko's name and STORE's resolved entry can
        # DISAGREE after a rename: the store's state is a projection sampled at some epoch, so
        # Decko may already hold a new name for a key the published state still carries under the
        # old one. Emitting Decko's name labelled as the resolved canonical name is therefore a
        # claim about the STORE that this deck cannot support.
        #
        # WHAT THE REAL STORE ACTUALLY SUPPLIES -- measured, not assumed. `#lookup` is answered by
        # I2-02 `buckets` (see `lookup_reading`). A probe of the REAL reader child
        # (`i2_stdio_reader_service.py`, argv `[interpreter, script]`, attested card-export
        # projection, sha256 f78ae2a6...22614) shows I2-02's resolved participant carries EXACTLY:
        #     participant keys = ["class", "digest", "key"]        -- no `name`, no `label`
        # addressed BY KEY and BY DIGEST alike. `_participant` builds the label/`name` pair ONLY
        # `if with_properties` (`i2_read.py:554-563`), and I2-02 calls it WITHOUT that flag
        # (`:754`). So on the op this endpoint uses, STORE SUPPLIES NO NAME AT ALL.
        #
        # THEREFORE THE KEY IS GONE, NOT REFILLED. VIEW cannot truthfully report a STORE-resolved
        # name that STORE never resolved, and K8's own contract does not ask it to: I3-10's Returns
        # column is "the entity for a card name, as `key` + `digest`, or `unknown`"
        # (`k8-draft-2.md:574`) -- there is NO `name` field in the lookup payload. Removing it
        # brings the payload INTO conformance rather than out of it, and the client never read it
        # (`live-bridge.mjs:759-760` checks only the envelope).
        #
        # DECKO'S NAME IS STILL USED, FOR ITS LEGITIMATE PURPOSE. `identity` remains the ACL
        # identity: it is what resolved the request string to a card and proved THIS CALLER may
        # read it. That is an authorization fact about Decko and it stays server-side. It is simply
        # not a STORE statement, so it is not emitted as one.
        #
        # THE NON-ORACLE PROPERTY IS UNWEAKENED. A miss and an unreadable card both still answer
        # `unknown` with no payload (`render_lookup_unknown`), so they remain indistinguishable;
        # dropping a key from the HIT shape cannot make the two MISS shapes differ.
        render_i3(reading, payload: {
                    "key" => key,
                    "digest" => digest
                  })
      end

      # --- I3 open: the card's own atoms ----------------------------------------------------------
      # CARD-SCOPED -> render_card_scoped (ACL-FILTERED). The payload is atoms belonging to a
      # specific card, so every atom must survive the caller's read authority.
      def open
        card_id = require_subject_card_id!
        return if performed?

        # Authorize the REQUESTED SOURCE CARD before touching the backend (see readable_source?).
        # An unreadable source answers with the ACL-FILTERED EMPTY SHAPE -- see render_acl_empty --
        # which is byte-identical to a card all of whose atoms were filtered, so this is not an
        # existence/permission oracle.
        return render_acl_empty unless readable_source?(card_id)

        render_card_scoped Atomspace::I3ReadPort.open_reading(card_id: card_id)
      end

      # --- I3 neighbours: atoms of adjacent cards -------------------------------------------------
      # CARD-SCOPED -> render_card_scoped (ACL-FILTERED). This is the handler where filtering matters
      # most: a neighbourhood is precisely where cards the caller may NOT read would otherwise leak,
      # and the filter's multi-card default-deny requires EVERY associated card id to be readable.
      def neighbours
        card_id = require_subject_card_id!
        return if performed?

        limit = parse_limit(params[:limit])
        return if performed?

        # THE INBOUND CURSOR, parsed and PROVEN STORE-ISSUED before the backend is touched. See
        # #parse_after_cursor for the whole argument; a malformed or unauthorizable cursor is
        # refused there and never forwarded.
        after = parse_after_cursor
        return if performed?

        # Authorize the REQUESTED SOURCE CARD before touching the backend. The output filter CANNOT
        # do this for us here: it selects on atom.associated_card_ids, and for a non-reference atom
        # atom.rb:20-25 yields [@card_id] -- the NEIGHBOUR's id, never the source's. So without this
        # gate the readable neighbours of a card the caller may NOT read are disclosed, which is an
        # existence/permission oracle on the source card.
        return render_acl_empty unless readable_source?(card_id)

        # SAME-PRINCIPAL CURSOR SCOPING. A cursor names a SUBJECT participant; presenting one whose
        # subject is not the card being requested, or is a card this caller may not read, would let
        # a continuation reach around the source gate just cleared above. Both are refused.
        return if after && !cursor_scope_authorized!(after, card_id)

        render_card_scoped Atomspace::I3ReadPort.neighbours_reading(
          card_id: card_id, bucket: params[:bucket].presence, limit: limit, after: after
        )
      end

      # --- I3-01 / I3-09 health: DECLARED CAPABILITY-MISSING --------------------------------------
      # STORE's health slice is O23-gated and deliberately absent ("Absent, not fabricated: health
      # (O23 gated)" -- i2_read.py:60). There is no health data to return and none will be invented,
      # so this is a typed refusal rather than a synthesized health block. 501: the capability does
      # not exist upstream, which is distinct from the 503 raised when a capability that DOES exist
      # is merely unready.
      def health
        render json: {
          error: "capability_missing",
          reason: "i3_health_slice_unavailable_o23_gated",
          _meta: i3_meta
        }, status: :not_implemented
      end

      private

      # IDENTITY TEARDOWN, and the session path makes this strictly load-bearing.
      #
      # BaseController's own after_action clears the MCP thread flag and `Card::Auth.current_id`
      # (base_controller.rb:23-26), but Rails SKIPS after_actions when a before_action halts --
      # and every gate here can halt. Hence the prepended around_action.
      #
      # `Card::Env.reset` (card/lib/card/env.rb:25-29) is ADDED for the session path:
      # #session_account binds `Card::Env.controller = self`, and `Card::Env` is MODULE-LEVEL
      # STATE (`Card::Env.reset` at env.rb:42 runs once at load). Under a preloaded, threaded
      # server a controller left bound there would be visible to a LATER request, whose
      # `Card::Auth.signin_with` would then read the PREVIOUS request's cookie -- i.e. answer one
      # user as another. Resetting to nil in an ensure block closes that window regardless of how
      # the action exits (render, halt, or raise).
      #
      # `Card::Auth.reset` clears @current_id/@as_id/@current_card/@current_roles together
      # (card/lib/card/auth/current.rb:78-80); BaseController's `current_id = nil` alone leaves
      # @current_roles cached, which is exactly the value the session role gate reads.
      #
      # ==== WHAT THIS TEARDOWN IS *NOT*: A CONCURRENCY GUARANTEE. READ BEFORE RAISING THREADS.
      #
      # `Card::Auth` and `Card::Env` are MODULE-LEVEL state, not per-request state. This block
      # makes the state clean BETWEEN SEQUENTIAL requests on the same thread; it CANNOT isolate two
      # requests running AT THE SAME TIME. With two concurrent requests in one process, request B's
      # `Card::Env.reset self` / `Card::Auth.signin_with` overwrites the module state request A is
      # still mid-action on, and A's subsequent card touches would run under B's identity -- one
      # user answered as another, which is the precise failure this file exists to prevent.
      #
      # Whether that is reachable depends on the thread count, and the SAFE VALUE IS THE DEFAULT:
      # `config/puma.rb:2-4` sets min/max threads from `RAILS_MIN_THREADS`/`RAILS_MAX_THREADS`
      # DEFAULTING TO 1, so an unconfigured deploy runs one request at a time and this path is
      # safe. The defaults are OVERRIDABLE by environment, though, so the constraint is a
      # PREREQUISITE and not an invariant:
      #
      #   OPERATOR PREREQUISITE -- the I3 read surface requires a SINGLE-THREADED server
      #   (RAILS_MAX_THREADS=1, the default). Raising RAILS_MAX_THREADS above 1 is NOT
      #   supported on this path until Card::Auth/Card::Env identity is made thread-local or
      #   mutex-serialised. It is not a performance tuning knob here; it is a correctness one.
      #
      # `assert_single_threaded_identity!` below enforces that at request time rather than leaving
      # it to a deploy note, because a documented prerequisite nobody reads is not a control.
      def clear_mcp_state_after_request
        assert_single_threaded_identity!
        assert_secure_transport!
        yield
      ensure
        begin
          Card::Auth.reset
          Card::Env.reset(nil)
        rescue StandardError => e
          Rails.logger.error("I3 identity teardown failed: #{e.class}")
        end
        clear_mcp_thread_flag
      end

      # The RUNTIME half of the prerequisite above. A multi-threaded server cannot isolate
      # module-level identity, so rather than silently serving under a configuration whose
      # isolation it cannot provide, this path REFUSES.
      #
      # Checked against the server's configured maximum, not the live thread count: a pool
      # configured for N>1 can interleave even if it happens to be idle right now, and the point is
      # to refuse the CONFIGURATION. Read from `RAILS_MAX_THREADS` ONLY -- that is the single input
      # `config/puma.rb:3` itself uses (`Integer(ENV["RAILS_MAX_THREADS"] || 1)`), so the env var IS
      # the configured value on this deck. (This deliberately does NOT consult a Puma runtime API:
      # no such accessor is verifiable from this repo, and inventing one would be a guess dressed as
      # a control.) An absent or unparseable value is treated as the safe default of 1, matching
      # config/puma.rb.
      #
      # RAISES ITS OWN CLASS, NOT Atomspace::ServiceUnavailable: this runs BEFORE authentication, so
      # its response must disclose nothing at all -- see UnsupportedServerConfiguration above. The
      # message below is for the SERVER-SIDE log only and never reaches the wire.
      #
      # @raise [UnsupportedServerConfiguration] when the server permits concurrent requests.
      def assert_single_threaded_identity!
        max = ENV["RAILS_MAX_THREADS"]
        return if max.nil? || max.to_s.strip.empty?

        configured = Integer(max, 10)
        return if configured <= 1

        raise UnsupportedServerConfiguration,
              "i3_read_requires_single_threaded_server: RAILS_MAX_THREADS=#{configured} permits " \
              "concurrent requests, and Card::Auth/Card::Env identity is module-level state that " \
              "cannot be isolated per request on this path"
      rescue ArgumentError, TypeError
        # An unparseable value is not a licence to assume concurrency is fine, but it is also not
        # evidence of it. config/puma.rb's own default is 1, so treat it as 1.
        nil
      end

      # THE TRANSPORT GATE. Reads the CAPTURED evidence ONLY -- never the live request.
      #
      # WHY NOT A before_action, AND WHY NOT request.ssl?. `ActionDispatch::AssumeSSL` REWRITES
      # the protocol evidence (HTTPS, HTTP_X_FORWARDED_PROTO, rack.url_scheme) on the env hash
      # before it calls the next app, and EVERY Rails-level hook -- before_action,
      # prepend_around_action, request.ssl?, request.scheme, request.headers["X-Forwarded-Proto"]
      # -- runs downstream of that rewrite. So a before_action asking `request.ssl?` reads the
      # constant "https" AssumeSSL just wrote, not what the client actually did; it would pass for
      # a cleartext request and is therefore not a control at all. That is the exact defect this
      # replaces. (Reviewer-asserted anchor: actionpack
      # .../action_dispatch/middleware/assume_ssl.rb:21 -- the LINE NUMBER is UNVERIFIED here,
      # actionpack is not resolvable on this host.)
      #
      # The fix is upstream capture: Atomspace::OriginalProtocolEvidence is inserted BEFORE
      # AssumeSSL (config/initializers/i3_transport_evidence.rb) and parks the pre-rewrite
      # evidence in `request.env["i3.original_transport"]`. This method consults that key and
      # nothing else.
      #
      # `request.socket_ssl?` IS NOT USED, and must not be reintroduced: it is not a Rails API and
      # raises NoMethodError, so a gate built on it fails on every request rather than gating
      # anything.
      #
      # DEFAULT-ON, AND FAIL-CLOSED IN EVERY DIRECTION. I3_REQUIRE_SECURE_TRANSPORT must be
      # exactly "0" to disable; anything else (unset included) enforces. When enforcing, a refusal
      # is issued unless the capture carries POSITIVE evidence of TLS:
      #   - middleware never ran / key absent        -> REFUSE (absence is not evidence)
      #   - capture failed internally                -> REFUSE
      #   - cleartext                                -> REFUSE
      #   - X-Forwarded-Proto: https from an address NOT in I3_TRUSTED_PROXY_CIDRS -> REFUSE
      #     (that header is a CLAIM by whoever connected; an unallowlisted claimant is a forger as
      #     far as this gate is concerned, and I3_TRUSTED_PROXY_CIDRS unset = trust nobody)
      #   - any exception at all                     -> REFUSE
      #
      # RAISES UnsupportedServerConfiguration, reusing the EXISTING pre-authentication refusal
      # path: that renders the frozen CONFIG_REFUSAL_BODY (503, no _meta, no Observability alert),
      # so a plaintext probe is INDISTINGUISHABLE from the ordinary backend-unavailable 503 and
      # raises no alert attributable to an unauthenticated caller. A new body or a new status would
      # have made a cleartext-refusing server fingerprintable and would have handed an
      # unauthenticated prober a signal; both are the things CONFIG_REFUSAL_BODY exists to avoid.
      # The diagnosis goes to Rails.logger only.
      #
      # RUNS HERE, inside the prepended around_action next to assert_single_threaded_identity!,
      # because transport is a precondition of even LOOKING at a credential: a cleartext request
      # must be refused before the session cookie or Bearer token it carries is read, parsed or
      # logged. A before_action could not do this even if the evidence were intact -- it runs after
      # the parent auth filter chain has begun.
      #
      # @raise [UnsupportedServerConfiguration] when secure transport cannot be positively proven.
      def assert_secure_transport!
        return unless i3_require_secure_transport?

        capture = request.env[Atomspace::OriginalProtocolEvidence::ENV_KEY]
        return if Atomspace::OriginalProtocolEvidence.secure?(capture)

        raise UnsupportedServerConfiguration,
              "i3_read_requires_secure_transport: no positive evidence of TLS for this request " \
              "(evidence=#{transport_evidence_digest(capture)}). Either the request reached the " \
              "origin in cleartext, or a forwarded protocol was claimed by a peer outside " \
              "I3_TRUSTED_PROXY_CIDRS, or the original-protocol-evidence middleware is not " \
              "installed upstream of ActionDispatch::AssumeSSL."
      rescue UnsupportedServerConfiguration
        raise
      rescue StandardError => e
        # The gate itself malfunctioning is NOT an allow.
        Rails.logger.error("I3 transport gate failed closed: #{e.class}")
        raise UnsupportedServerConfiguration,
              "i3_read_transport_gate_error: #{e.class}"
      end

      # "0" disables; unset or anything else enforces. Default-ON by construction, so forgetting
      # to set the var leaves the control ON rather than off.
      def i3_require_secure_transport?
        ENV["I3_REQUIRE_SECURE_TRANSPORT"].to_s.strip != "0"
      end

      # SERVER-SIDE LOG ONLY. Never rendered -- CONFIG_REFUSAL_BODY is a frozen constant with
      # nothing derived from the request, and that is the point. Kept to the fields an operator
      # needs to tell "cleartext" from "untrusted claimant" from "middleware missing".
      def transport_evidence_digest(capture)
        return "absent" unless capture.is_a?(Hash)
        return "capture_failed(#{capture[:error]})" unless capture[:captured]

        "scheme=#{capture[:url_scheme].inspect} " \
          "xfp_first_hop=#{capture[:forwarded_proto_first_hop].inspect} " \
          "https_env=#{capture[:https_env].inspect} " \
          "remote_addr=#{capture[:remote_addr].inspect} " \
          "remote_trusted=#{capture[:remote_trusted].inspect}"
      rescue StandardError
        "undiagnosable"
      end

      # GENUINE, caller-authorized name resolution. Runs under the CALLER's identity -- never
      # as_bot, never a service account -- and applies the concern's default-deny before ok?(:read).
      #
      # NOW DELEGATES to Atomspace::CallerScopedCardAuthorization so this decision has exactly ONE
      # implementation. It used to be inline here and therefore unreachable from anywhere else,
      # which is why the authorization bridge had no primitive to call; two copies of an ACL check
      # is how the two drift apart.
      #
      # IT RETURNS THE IDENTITY, NOT A BARE ID. The old version held `card` in scope and discarded
      # everything but `card.id`, which is exactly the gap that blocked the bridge: the Python side
      # requires (card_id, canonical_name) and refuses a bare id as carrying no proof of the ACL
      # check. `#lookup` still uses only the id; the canonical name is now AVAILABLE rather than
      # thrown away.
      # @return [Atomspace::AuthorizedCardIdentity, nil] nil when absent OR not readable.
      def readable_identity_for_name(name)
        Atomspace::CallerScopedCardAuthorization.readable_identity_for_name(
          name, account: @current_mcp_account, readable: method(:readable_card?)
        )
      end

      # Back-compat shim, kept because #lookup wants only the id and reads better for it.
      # @return [Integer, nil]
      def readable_card_id_for_name(name)
        readable_identity_for_name(name)&.card_id
      end

      # GENUINE, caller-authorized SOURCE-CARD authorization for the card-scoped reads. Mirrors
      # readable_card_id_for_name exactly: runs under the CALLER's identity -- never as_bot, never a
      # service account -- and applies the concern's default-deny before ok?(:read).
      #
      # WHY AN UNREADABLE SOURCE COLLAPSES TO THE SAME RESPONSE AS AN EMPTY ONE: a distinct error
      # code or status would itself be the leak. "You may not read card N" confirms that card N
      # exists, and a 404-vs-403 split turns this endpoint into an existence/permission oracle on
      # the source card. #lookup already collapses not-found and not-readable into one `unknown`
      # answer for the same reason (see :88); here the equivalent non-oracle answer is an empty
      # filtered result in open/neighbours' NORMAL success shape -- indistinguishable from a card
      # that genuinely has no readable atoms, and no new wire vocabulary.
      # @return [Boolean] false when the card is absent OR not readable by this caller.
      #
      # DELEGATES to the same shared module as #readable_identity_for_name, for the same reason:
      # one implementation of the ACL decision, reachable by the bridge as well as the controller.
      def readable_source?(card_id)
        Atomspace::CallerScopedCardAuthorization.readable_card_id?(
          card_id, account: @current_mcp_account, readable: method(:readable_card?)
        )
      end

      # Strict parse: a non-digit card_id is a CLIENT error (400), never coerced with .to_i and never
      # a 500. The route additionally pins `constraints: {id: /\d+/}` + `format: false`.
      def require_card_id!
        raw = params[:id].to_s
        return raw.to_i if raw.match?(/\A\d+\z/)

        render_bad_request("card_id_invalid")
        nil
      end

      # ================================================================================================
      # THE SUBJECT-ADDRESS GATE for I3-02 `open` / I3-03 `neighbours`.
      #
      # WHY THIS EXISTS: A SHIPPED, DEPLOYMENT-AFFECTING CONTRACT MISMATCH, TODAY MASKED.
      # The shipped browser client addresses the participant by KEY, not by numeric id. After its
      # I3-10 `lookup` returns a key it sends the KIND-PRESERVING form `~k<key>`
      # (live-bridge.mjs:1223-1224 builds `{kind: 'key', text: lookup.key}`; :482-498 `addressParam`
      # renders `~k` + percent-encoded text; :653-654 and :710-717 put it on the wire as
      # `participant=`). This controller read ONLY `params[:id]` and validated `\A\d+\z`
      # (:616-622), so EVERY such request answered 400 `card_id_invalid`. It is masked right now
      # only because the client's step-1 `lookup` fails earlier with `i2_store_not_ready`, so step 2
      # is never reached -- the moment a real store projection makes `lookup` answer `ok`, the next
      # call hard-fails. The client is a hash-pinned read-only artifact, so the fix is deck-side.
      #
      # WHAT IS ACCEPTED -- `id` STAYS EXACTLY AS IT WAS, `participant` IS ADDITIVE:
      #   * `id=<digits>`          -> unchanged, still via require_card_id! and its strict \A\d+\z.
      #   * `participant=~k<key>`  -> a STORE participant KEY TEXT; the card id is recovered from
      #                               the one documented `(Card <digits>)` form and authorized by
      #                               the EXISTING caller-scoped `readable_source?`.
      #   * `participant=~<id>`    -> Decko numeric reference; the digits are the card id.
      #   * `participant=<name>`   -> a bare name, the client's third declared form
      #                               (live-bridge.mjs:497 `kind === 'name'`).
      # `id` WINS when both are present: it is the pre-existing parameter and the stricter one, so
      # no existing caller's meaning changes. Neither present -> the UNCHANGED `card_id_invalid`.
      #
      # RESOLUTION REUSES THE AUTHORIZED PATH; IT DOES NOT REIMPLEMENT ONE. A BARE NAME goes
      # through #readable_identity_for_name -> Atomspace::CallerScopedCardAuthorization
      # (caller_scoped_card_authorization.rb:58-73), which runs `Card.fetch` INSIDE
      # `Card::Auth.as(account.name)` -- the CALLER's identity -- with AtomspaceReadFilter's
      # default-deny applied BEFORE `ok?(:read)`. No `as_bot`, no service account, no admin subject
      # substitution, and no second copy of the ACL check.
      #
      # `~k` IS A STORE KEY TEXT, NOT A DECKO NAME, AND IS NO LONGER TREATED AS ONE. `~k` / `~` are
      # stripped as the documented STRUCTURAL prefixes of the wire grammar (live-bridge.mjs:467-477),
      # but what remains after `~k` is STORE's OWN key text -- `(Card <id>)`, the form
      # `participant_key_for` (i2_reader_process_client.rb:579-585) produces to ADDRESS the store --
      # which is NOT a Decko card name and must never be resolved as one. Handing it to the NAME
      # resolver always answered nil, so every key-addressed request silently answered empty while
      # the card id sat in plain sight inside the text. The id is now recovered through the SAME
      # single mapper `store_identity_readable?` uses (#card_id_from_store_key_text -- one regex,
      # one implementation) and authorized by `readable_source?`, the same caller-scoped
      # default-deny check #open (:499) and #neighbours (:520) gate on. Text that is NOT that one
      # documented form is NOT guessed at: it fails closed to the empty answer, untouched card.
      #
      # AND IT CANNOT BECOME AN EXISTENCE ORACLE. Each resolution form already collapses ABSENT and
      # UNREADABLE to one indistinguishable answer -- the name resolver by returning a single nil
      # (invariant 4, caller_scoped_card_authorization.rb:28-30), and the `~k` key path because a
      # key that maps to no card, maps to a card the caller may not read, or is not the documented
      # form at all all reach the SAME place. That place is `render_acl_empty` -- byte-for-byte the
      # SAME 200 + empty-results answer that #open/#neighbours already give for a numeric id that is
      # absent or unreadable (:499, :520). So "no such card", "exists but you may not read it",
      # "that key is not a form this deck can map" and "exists, readable, no atoms" are ALL the same
      # response, and no new status, error code or reason distinguishes them. (It is NOT
      # `render_card_scoped([])`: that path now requires an Atomspace::I3ReadResult and answers a
      # 503 `i3_backend_result_contract_violation` on a bare Array -- see :1015-1018 -- which is why
      # the typed empty answer `render_acl_empty` is the only correct empty here.) The 400s below
      # are reachable ONLY by input that is malformed as a STRING -- decided before any card is
      # touched, so they reveal nothing about any card.
      #
      # PERCENT-DECODED EXACTLY ONCE, and only when Rack has not already done it. Rack decodes the
      # query string, so `params[:participant]` is normally already decoded and decoding again
      # would corrupt a name legitimately containing `%` (and would re-expose the `%7E` -> `~`
      # ambiguity the client encodes AGAINST, live-bridge.mjs:430-434). A second decode is applied
      # ONLY to the raw query bytes when the param arrives still encoded, never to a decoded value.
      #
      # `distance` IS DELIBERATELY IGNORED -- DECIDED, NOT OVERLOOKED. The client always sends it
      # (live-bridge.mjs:655, :724). This surface has no distance semantics: that is an I2 store
      # concept, the store projection is not wired here, and honouring it would mean either
      # fabricating a traversal depth deck-side or adding a new RESERVED I2 config parameter --
      # out of scope, and the I2 config schema REFUSES unknown keys. Refusing the request instead
      # would break the shipped client on every call for a parameter it is contractually required
      # to send. So it is ACCEPTED AND IGNORED, matching this controller's existing posture toward
      # inputs it does not implement (`limit` is documented `pre_auth_best_effort` at :681 rather
      # than refused; the surface declares capability gaps instead of faking them, :45-47). NO new
      # reserved parameter is introduced and nothing is fabricated. OPERATOR NOTE: responses to a
      # request carrying `distance` are NOT distance-limited; a future implementation must land in
      # the store, not here.
      #
      # @return [Integer, nil] a card id to read, or nil when a refusal/empty answer was rendered.
      def require_subject_card_id!
        # The pre-existing parameter keeps precedence and its exact old behaviour.
        return require_card_id! if params[:id].present?
        return require_card_id! if params[:participant].blank?

        reference = participant_reference_param
        return nil if performed?

        resolve_participant_reference!(reference)
      end

      # The RAW `participant` value, percent-decoded exactly once, with its string-level grammar
      # enforced BEFORE any card is touched. Refusals here are decided from the string alone.
      #
      # @return [String, nil] nil when a 400 was rendered.
      def participant_reference_param
        raw = params[:participant].to_s

        # Length is bounded on the ENCODED-or-decoded string first: an overlong value must be
        # refused without being decoded, expanded or fetched.
        if raw.bytesize > MAX_PARTICIPANT_BYTES
          render_bad_request("participant_too_long")
          return nil
        end

        decoded = decode_participant_once(raw)
        if decoded.nil?
          render_bad_request("participant_malformed_encoding")
          return nil
        end
        if decoded.bytesize > MAX_PARTICIPANT_BYTES
          render_bad_request("participant_too_long")
          return nil
        end
        if decoded.strip.empty?
          render_bad_request("participant_required")
          return nil
        end
        # A control character cannot occur in a legitimate Decko name and is a strong smell of an
        # injection or a mis-encoded transport. Refused on the string, never fetched.
        if decoded.match?(/[\u0000-\u001f\u007f]/)
          render_bad_request("participant_malformed")
          return nil
        end

        decoded
      end

      # Rack has normally already decoded the query string, so decoding `params[:participant]`
      # again would corrupt any name legitimately containing `%`. A second decode is therefore
      # applied ONLY when the value arrives still percent-encoded -- detected by comparing against
      # the raw query string rather than by guessing from the value's own shape.
      #
      # @return [String, nil] nil when the value is not valid UTF-8 after decoding.
      def decode_participant_once(raw)
        value = raw
        if participant_still_encoded?(raw)
          begin
            value = CGI.unescape(raw)
          rescue ArgumentError
            return nil
          end
        end
        value = value.dup.force_encoding(Encoding::UTF_8)
        value.valid_encoding? ? value : nil
      end

      # True only when the RAW QUERY STRING contains this exact value percent-encoded, i.e. Rack
      # did not decode it for us. Conservative: any uncertainty answers false and the value is
      # used as-is rather than decoded a second time.
      def participant_still_encoded?(raw)
        query = request.query_string.to_s
        return false if query.empty? || !raw.include?("%")

        query.include?("participant=#{raw}")
      rescue StandardError
        false
      end

      # Turn a validated reference STRING into a card id, under the caller's own authority.
      #
      # ONE AUTHORIZATION PER FORM, AND NO FORM INVENTS ITS OWN. A bare NAME ends at
      # #readable_identity_for_name; a `~k` STORE KEY and a `~<id>` numeric reference both end at
      # #readable_source?. Both of those are the shared CallerScopedCardAuthorization default-deny
      # decision, so this method adds no authorization logic of its own and holds no second copy.
      #
      # EVERY NON-ANSWER IS THE SAME ANSWER. Absent, unreadable, and a `~k` key this deck cannot map
      # all return via #render_acl_empty, which takes no arguments and derives its envelope from
      # STORE's I2-01 status (see :1153-1175). Nothing distinguishes them for the caller.
      #
      # @return [Integer, nil] nil when an empty-result/refusal was already rendered.
      def resolve_participant_reference!(reference)
        return nil if reference.nil?

        name =
          if reference.start_with?("~k")
            # `~k` is the STRUCTURAL key prefix (live-bridge.mjs:468). What follows is STORE's KEY
            # TEXT -- NOT a Decko name, so it must NOT go to the name resolver (that is the defect
            # this repairs: `(Card 2)` is not a card name and resolved to nil forever, while the id
            # it contains was never read out). The id is recovered from the ONE documented form via
            # the SAME mapper store_identity_readable? uses, then authorized by the SAME
            # caller-scoped default-deny check the numeric path uses.
            #
            # FAIL-CLOSED: an unmappable key text (a link key, a digest-shaped string, `(Card 0)`,
            # a non-positive or non-numeric id, empty) is NEVER guessed at and never becomes a card
            # read. It renders the same empty answer as an unreadable card, so a caller cannot tell
            # a bad key from a denied card from an absent one.
            return resolve_participant_key_reference!(reference[2..].to_s)
          elsif reference.match?(/\A~\d+\z/)
            # `~<id>` is Decko's numeric reference form: the digits ARE the card id, so this joins
            # the numeric path and gets the numeric path's authorization (readable_source?).
            return reference[1..].to_i
          elsif reference.start_with?("~d")
            # `~d<32hex>` is a STORE digest (live-bridge.mjs:491-495). This deck has no
            # digest->card resolver -- i3_read_controller.rb:311-319 records that the store exposes
            # no such resolver and that computing one deck-side is FORBIDDEN -- so this is a
            # declared capability gap, reported as one, never guessed at.
            render_unavailable("i3_participant_digest_resolution_unavailable")
            return nil
          else
            # A bare name, the client's third declared address form (live-bridge.mjs:497).
            reference
          end

        if name.strip.empty?
          render_bad_request("participant_malformed")
          return nil
        end

        identity = readable_identity_for_name(name)
        # ABSENT and UNREADABLE are already indistinguishable here (the resolver collapses them),
        # and this renders the SAME empty 200 that an absent-or-unreadable NUMERIC id produces
        # (:499, :520) and that an unmappable `~k` key produces. No distinct status, code or
        # reason -- so no existence oracle and no enumeration signal.
        return identity.card_id if identity

        render_acl_empty
        nil
      end

      # The `~k` branch of #resolve_participant_reference!: a STORE participant key TEXT (the `~k`
      # prefix already stripped) to an authorized card id.
      #
      # NO SECOND ACL CHECK AND NO SECOND PARSER. The text->id mapping is #card_id_from_store_key_text
      # (shared with store_identity_readable?) and the ACL decision is #readable_source? -- the same
      # one #open (:499) and #neighbours (:520) gate on. An unmappable key and an unreadable card
      # deliberately take the SAME exit, so neither is distinguishable from the other or from a
      # readable card with no atoms.
      #
      # @return [Integer, nil] nil when the empty answer was already rendered.
      def resolve_participant_key_reference!(key_text)
        card_id = card_id_from_store_key_text(key_text)

        # Unmappable key text: fail closed. No card is touched and no refusal code is minted -- the
        # answer is the ordinary empty one, so a malformed key reveals nothing a denied card does not.
        unless card_id
          render_acl_empty
          return nil
        end

        unless readable_source?(card_id)
          render_acl_empty
          return nil
        end

        card_id
      end

      # The ONE place a STORE key text is mapped to a decko card id.
      #
      # Only the single documented participant-key form is recognised -- `(Card <digits>)`, exactly
      # what `participant_key_for` (i2_reader_process_client.rb:579-585) produces when ADDRESSING
      # the store. Everything else (a link key, a bare digest, a name, a non-positive id, nil, a
      # non-String) is UNMAPPABLE and answers nil, because an identity this deck cannot map to a
      # card is one it cannot authorize.
      #
      # Deliberately shared by #store_identity_readable? (continuation authorization) and
      # #resolve_participant_key_reference! (subject addressing): two copies of this regex is how
      # the two drift apart, and they must agree on exactly which keys are addressable.
      #
      # @return [Integer, nil] a positive card id, or nil when the text is not the documented form.
      def card_id_from_store_key_text(key_text)
        return nil unless key_text.is_a?(String)

        match = /\A\(Card (\d+)\)\z/.match(key_text)
        return nil unless match

        card_id = match[1].to_i
        card_id.positive? ? card_id : nil
      end

      def parse_limit(raw)
        return nil if raw.blank?
        return raw.to_i if raw.to_s.match?(/\A\d+\z/) && raw.to_i.positive?

        render_bad_request("limit_invalid")
        nil
      end

      # ================================================================================
      # THE INBOUND CONTINUATION CURSOR (`after`) -- PARSED, ALLOWLISTED, AUTHORIZED.
      # ================================================================================
      #
      # (a) IT IS GOVERNED VOCABULARY, NOT AN INVENTION. `after` is I3-03's own documented
      #     continuation input -- "`participant`; `bucket`; `after` (cursor); `distance`"
      #     (`k8-draft-2.md:567`, `k8-draft-2-addendum-1.md:285`) -- carried as a query parameter
      #     because "All inputs are query parameters. No endpoint accepts a body." (`:288`). It maps
      #     onto I2-03's own `after` argument (`:1037`). So reading `params[:after]` adds NO wire
      #     vocabulary; the previous note here ("this surface has no cursor parameter") described
      #     an UNIMPLEMENTED parameter, not a forbidden one, and its absence is what made every
      #     truncated page a dead end.
      #
      # (b) ONLY A STORE-ISSUED CURSOR IS EVER FORWARDED. This deck MUST NOT construct, synthesise,
      #     extend or repair a cursor, so the value is accepted only when its SHAPE matches what
      #     STORE issues, with an EXACT-KEY ALLOWLIST and per-key TYPE constraints
      #     (CURSOR_KEY_TYPES, measured on STORE 042 seq 17-20). An unknown key, a wrong type, a
      #     missing required key or excess depth is a REFUSAL -- never a silent repair, never a
      #     "best effort" pass-through. A forged or hand-built cursor therefore cannot enter the
      #     chain, and a cursor STORE did not issue cannot be made to look like one.
      #
      # (c) IT IS NOT TRUSTED BLINDLY, AND THAT IS THE WHOLE POINT. The identities INSIDE the
      #     cursor face the SAME caller-scoped, default-deny ACL as every other identity, via the
      #     SAME `store_identity_readable?` predicate (see #cursor_scope_authorized! and
      #     I3Envelope's identity walk). Freshness is checked too: the cursor's `epoch`/`position`
      #     are validated against STORE's OWN published state, so a cursor minted against a state
      #     this deck cannot confirm is refused rather than replayed.
      #
      # (d) A CURSOR CAN ONLY NARROW. The outbound list is re-filtered per request under the
      #     presenting identity (see #render_card_scoped), so even a legitimately issued cursor
      #     yields only what ITS presenter may read. Combined with (c)'s subject check, a cursor
      #     cannot widen scope, cannot cross principals and cannot address another card.
      #
      # (e) NO NEW REFUSAL VOCABULARY. Refusals reuse the EXISTING `render_bad_request` path with
      #     reason strings in the established `<thing>_invalid` form.

      # The EXACT keys STORE's own cursor carries, with the type each may hold. Measured verbatim
      # on the real reader child (STORE 042 seq 17-20 `payload.omitted.continue`):
      #     {"kind": "entries", "participant": "(Card 19357)", "bucket": "links-to",
      #      "narrowing": null, "after": ["(Card 19360)", "", -1],
      #      "epoch": "c1877b24303a4eda8b69d73fbe3dd249", "position": 2}
      # plus the link-level cursor's own members (`i2_read.py:615-618`). The enumeration is CLOSED:
      # an unrecognised key could be a future identity form, so it fails closed.
      CURSOR_KEY_TYPES = {
        "kind" => [String],
        "participant" => [String],
        "bucket" => [String],
        "narrowing" => [NilClass, Hash],
        "after" => [Array, String],
        "after-link" => [String],
        "neighbour" => [Array, String],
        "epoch" => [String],
        "position" => [Integer],
        "key" => [String],
        "digest" => [String],
        "cursor" => [NilClass, Hash],
        "reason" => [String]
      }.freeze

      # The keys a cursor MUST carry to be a continuation this deck will forward. STORE issues all
      # four on every real page-out cursor; a value missing any of them is not a cursor STORE
      # minted, and this deck will not complete it.
      CURSOR_REQUIRED_KEYS = %w[kind participant bucket epoch position].freeze

      # Element types admissible inside a cursor ORDER TUPLE (`after` / `neighbour`). STORE's real
      # tuple is `["(Card 19360)", "", -1]`: a key text, a padding slot, an order coordinate.
      CURSOR_TUPLE_ELEMENT_TYPES = [String, Integer, Float, NilClass, TrueClass, FalseClass].freeze

      # Ceiling on nested cursor structure, mirroring I3Envelope::CONTINUE_MAX_DEPTH's reasoning: a
      # structure too deep to finish auditing is refused, not assumed benign.
      CURSOR_MAX_DEPTH = 8

      # The validated, STORE-issued `after` cursor for this request, or nil when none was sent.
      #
      # Renders a refusal and returns nil when the parameter is present but is not a cursor this
      # deck can prove STORE issued. Callers must check `performed?`.
      def parse_after_cursor
        raw = params[:after]
        return nil if raw.blank?

        decoded = decode_after_cursor(raw)
        if decoded.nil?
          render_bad_request("after_invalid")
          return nil
        end

        unless cursor_shape_valid?(decoded, 0)
          render_bad_request("after_invalid")
          return nil
        end

        unless CURSOR_REQUIRED_KEYS.all? { |k| decoded.key?(k) }
          render_bad_request("after_invalid")
          return nil
        end

        decoded
      end

      # The cursor as a mapping, or nil when it cannot be read as one.
      #
      # The client sends the STORE-issued object JSON-encoded in one query parameter (it forwards
      # the opaque value it was handed, `live-bridge.mjs` `neighboursPairs`). A non-JSON or
      # non-object value is NOT coerced, padded or wrapped -- it is refused, because anything this
      # deck would have to BUILD is by definition not a cursor STORE issued.
      def decode_after_cursor(raw)
        text = raw.to_s
        return nil if text.bytesize > CURSOR_MAX_BYTES

        parsed = begin
          JSON.parse(text)
        rescue JSON::ParserError, TypeError
          nil
        end
        parsed.is_a?(Hash) ? parsed : nil
      end

      # §5.4's per-parameter ceiling: "any single query parameter value, is limited to 2,000 bytes"
      # (`k8-draft-2.md:537-538`). Enforced before parsing so an oversized value is never walked.
      CURSOR_MAX_BYTES = 2_000

      # Is this value shaped EXACTLY like a cursor STORE issues? Exact-key allowlist + per-key
      # types + depth ceiling, applied recursively. No key is added, defaulted or repaired.
      def cursor_shape_valid?(node, depth)
        return false if depth > CURSOR_MAX_DEPTH
        return false unless node.is_a?(Hash)

        node.all? do |key, value|
          types = CURSOR_KEY_TYPES[key.to_s]
          # An UNRECOGNISED KEY fails closed: it could be a future identity form.
          next false if types.nil?
          next false unless types.any? { |t| value.is_a?(t) }

          case value
          when Hash then cursor_shape_valid?(value, depth + 1)
          when Array then cursor_tuple_valid?(value, key.to_s)
          else true
          end
        end
      end

      # An ORDER TUPLE holds only scalars. A nested container inside one is a shape this deck
      # cannot audit as an order coordinate, so it is refused.
      def cursor_tuple_valid?(value, key)
        return false unless %w[after neighbour].include?(key)

        value.all? { |e| CURSOR_TUPLE_ELEMENT_TYPES.any? { |t| e.is_a?(t) } }
      end

      # SAME-PRINCIPAL, SAME-SUBJECT, STATE-CONFIRMED cursor scoping.
      #
      # Three checks, each closing a distinct way a continuation could reach past the gates the
      # request already cleared. Renders a refusal and returns false on any failure.
      #
      #   1. THE SUBJECT MUST BE THIS REQUEST'S CARD. STORE's cursor names the participant it was
      #      issued for. Honouring a cursor whose subject is a DIFFERENT card would read that other
      #      card's neighbourhood under this request's already-passed source authorization -- the
      #      exact scope-widening a cursor must never achieve.
      #   2. THE SUBJECT MUST BE READABLE BY THIS CALLER. Checked through the SAME default-deny
      #      `store_identity_readable?` used everywhere else, so a cursor issued to one principal
      #      is inert in another's hands. One ACL, asked again.
      #   3. THE STATE MUST BE ONE STORE CONFIRMS. The cursor's `epoch`/`position` are compared
      #      against STORE's OWN published state envelope. A cursor minted against a state this
      #      deck cannot confirm is refused rather than replayed blind. Freshness BEYOND that --
      #      whether the bucket changed within the epoch -- is STORE's to report via `cursor-stale`
      #      (§5.8), which this deck forwards and does not second-guess.
      def cursor_scope_authorized!(after, card_id)
        subject = after["participant"]
        expected = Atomspace::I2ReaderProcessClient.participant_key_text(card_id)
        if !subject.is_a?(String) || subject != expected
          render_bad_request("after_invalid")
          return false
        end

        unless store_identity_readable?(subject)
          render_bad_request("after_invalid")
          return false
        end

        unless cursor_state_confirmed?(after)
          render_bad_request("after_invalid")
          return false
        end

        unless cursor_identities_authorized?(after)
          render_bad_request("after_invalid")
          return false
        end

        true
      end

      # EVERY IDENTITY CARRIED BY AN INBOUND CURSOR MUST ITSELF BE READABLE BY THIS CALLER.
      #
      # THE ASYMMETRY THIS CLOSES, and it was a real hole, not a theoretical one. The OUTBOUND
      # side already refuses to emit a continuation whose anchor the caller cannot read
      # (`continue_identity_authorized?`, i3_envelope.rb) -- that is what makes the three-page stop
      # correct. But the INBOUND side checked only the cursor's SUBJECT, its epoch, and its shape.
      # So a caller who could read `(Card 19357)` could hand back a cursor whose `after` anchor
      # named `(Card 19372)` -- a card it cannot read -- and that anchor was relayed VERBATIM to
      # STORE as an order coordinate. Withholding an address on the way out while accepting the
      # same address on the way in is not a policy; the gate has to hold in both directions.
      #
      # THE SAME WALKER AND THE SAME ACL, ASKED AGAIN. This reuses `continue_identity_authorized?`
      # -- the exact function that guards the outbound cursor -- with `store_identity_readable?`,
      # the one caller-scoped default-deny check used everywhere else in this controller. No new
      # predicate, no second notion of readability, and no new wire vocabulary: the refusal is the
      # EXISTING `after_invalid`. Non-identity slots are unaffected, because that walker already
      # treats an empty string and a numeric order coordinate as naming nobody.
      #
      # DEFAULT-DENY ON SHAPE. Only the identity-bearing keys are examined; `nil` is permitted
      # because §5.8's `no-such-bucket` cursor legitimately names nobody. Anything else under one
      # of those keys fails the walker and is refused rather than forwarded.
      #
      # THE KEY SET AND THE WALKER BOTH LIVE IN I3Envelope, which is where the OUTBOUND cursor is
      # guarded. This asks that module its own question through its public
      # #inbound_cursor_authorized? entry point rather than re-listing the identity keys here, so
      # inbound and outbound cannot drift into two different notions of "identity-bearing".
      def cursor_identities_authorized?(after)
        Atomspace::I3Envelope.inbound_cursor_authorized?(
          after, method(:store_identity_readable?)
        )
      rescue StandardError => e
        # An authorization walk that RAISED has authorized nothing.
        Rails.logger.warn("I3 inbound cursor identity authorization failed: #{e.class}")
        false
      end

      # Does STORE's own published state confirm the epoch this cursor was issued at?
      #
      # A DIFFERENT epoch means the cursor predates a reprojection; §5.8's own table answers that
      # case with `reload` (`k8-draft-2.md:741-745`), which is STORE's verdict to issue, so the
      # cursor is not forwarded as if it were current. When STORE's state CANNOT be read this
      # returns false: an unconfirmable cursor is refused, not trusted.
      def cursor_state_confirmed?(after)
        envelope = store_state_envelope
        return false unless envelope.is_a?(Hash)

        epoch = envelope["epoch"]
        return false unless epoch.is_a?(String) && !epoch.empty?

        after["epoch"] == epoch
      rescue StandardError => e
        Rails.logger.warn("I3 cursor state confirmation failed: #{e.class}")
        false
      end

      # ACL-FILTERED render. Mirrors render_card_scoped in atomspace_mirror_controller.rb:187-192.
      #
      # SHAPE VALIDATION BEFORE FILTERING (and the empty-vs-malformed distinction is the point).
      # This used to be `Array(atoms)`, which maps nil to [] -- so a port that answered nil, or
      # whose implementation silently returned no value at all, rendered a 200 with an EMPTY
      # results list that is INDISTINGUISHABLE from a card that genuinely has no readable atoms.
      # A malformed upstream answer is a BACKEND FAILURE, not an empty neighbourhood, and
      # conflating them means a caller cannot tell "nothing is there" from "the backend did not
      # answer".
      #
      # So:
      #   * a real Array -- INCLUDING an EMPTY one -- is a legitimate result and renders normally
      #     (the empty case is load-bearing: readable_source? and the ACL filter both answer with
      #     a deliberately empty collection, and those must stay 200);
      #   * anything that is NOT an Array (nil, a Hash, a bare atom, a String) is refused;
      #   * and each element must satisfy the atom contract the filter and the serializer actually
      #     call -- associated_card_ids (atomspace_read_filter.rb:16-19) and to_h (below). An
      #     element missing either would otherwise NoMethodError into the generic 500 path.
      #
      # Refused through the EXISTING render_unavailable path with the EXISTING
      # "i3_backend_unavailable" error code, so this adds NO new wire vocabulary; the reason
      # string distinguishes the two sub-cases for operators.
      #
      # PER-REQUEST, PER-CARD RE-FILTERING IS UNCONDITIONAL, and this is the whole cursor answer.
      # `filter_by_read_auth` runs HERE, on the way out, on EVERY response, under
      # `Card::Auth.as(@current_mcp_account.name)` -- the identity THIS request authenticated. So:
      #
      #   * every atom, including every NEIGHBOUR and every LINK/reference entry, is checked
      #     against the CURRENT caller's read authority on the CURRENT request. The filter's
      #     multi-card default-deny requires EVERY id in associated_card_ids to be readable
      #     (atomspace_read_filter.rb:13-22), so a reference whose referee the caller cannot read
      #     is dropped, not partially rendered;
      #   * NOTHING arriving from the port is ever treated as pre-authorized. The controller holds
      #     no per-caller result cache and no authorization memo, so there is no path by which a
      #     list assembled for one identity can be emitted to another;
      #   * consequently a CURSOR cannot widen scope. This surface has no cursor parameter (adding
      #     one would be new wire vocabulary, which O25 forbids) and MUST NOT acquire one that
      #     bypasses this call: because the gate is applied to the OUTBOUND list rather than to the
      #     request that produced it, any future continuation token would still be re-filtered
      #     under whoever presents it, and could only ever NARROW -- never widen -- what that
      #     identity may see.
      def render_card_scoped(reading)
        unless reading.is_a?(Atomspace::I3ReadResult)
          return render_unavailable("i3_backend_result_contract_violation")
        end

        # STORE answered `unknown` -- no participant, so no atom list at all. Rendered with STORE's
        # OWN envelope. `results` is deliberately ABSENT rather than `[]`: an empty list would
        # assert "this participant exists and has no atoms", which is a different and false claim.
        if reading.atoms.nil?
          return render_i3(reading, payload: {})
        end

        atoms = reading.atoms
        unless atoms.all? { |a| a.respond_to?(:associated_card_ids) && a.respond_to?(:to_h) }
          return render_unavailable("i3_backend_atom_contract_violation")
        end

        filtered = filter_by_read_auth(atoms, @current_mcp_account)

        payload = { "results" => filtered.map(&:to_h) }

        # ====================================================================================
        # THE ACL OMISSION IS *NOT* PUT ON THE WIRE, AND THAT IS AN ACKNOWLEDGED CONTRACT GAP.
        # ====================================================================================
        #
        # (a) WHAT HAPPENED. `filter_by_read_auth` removed `removed` atoms that STORE did return.
        #     This deck caused a real omission and the count is exact, not estimated.
        #
        # (b) THE MANDATE TO LABEL IT. K8 §5.8 is unambiguous: "every omission is labelled (N09)"
        #     (`k8-draft-2.md:777`) and "There is no silent drop anywhere in I3" (`:810`). By that
        #     text this omission OUGHT to be labelled on the wire.
        #
        # (c) WHY IT IS NOT, AND WHY NOTHING IS INVENTED HERE. The ONLY omission-labelling vehicle
        #     K8 defines is `omitted`, and its `bound` enumeration is CLOSED at exactly seven
        #     members (`k8-draft-2.md:782-789`): entries, connections, bytes, budget,
        #     refresh-participants, ambiguous-digest, no-such-bucket. There is NO ACL member, and
        #     `:752-754` states that the limit sentence "governs the three limit cases only" and
        #     that a reader of `bound` "must not infer that a limit was hit". So an ACL drop has NO
        #     LANDING PLACE in the contract as written:
        #       * coining an EIGHTH `bound` value would reopen a closed enumeration; and
        #       * coining a new SIBLING top-level key -- which is what the previously-emitted
        #         `acl-filtered-count` was -- is NEW WIRE VOCABULARY invented by this lane.
        #     `acl-filtered-count` appears NOWHERE in the governing corpus: zero occurrences in
        #     `k8-draft-2.md`, `k8-draft-2-addendum-1.md`, `k8-draft-2-coordination-note.md` or
        #     `k8-draft-2-amendment-ledger-staged-20261113.md`, and zero in av-client. The client's
        #     own `checkI3Body` reads only `outcome`, the six envelope fields and the state triple,
        #     and its doc comment says so explicitly: "It does NOT check `limits`, `health`, or any
        #     payload key" (`live-bridge.mjs:759-760`). Emitting the key therefore bought no
        #     consumer anything while asserting vocabulary no contract contains.
        #
        # (d) IT IS NOT OURS TO RATIFY. The structurally identical case -- adding a member to this
        #     very enumeration -- is O21, and it required Lake's EXPLICIT ratification before it
        #     could be written down (`k8-draft-2-amendment-ledger-staged-20261113.md:72`;
        #     `k8-draft-2-addendum-1.md:213-224`). This is an UNRESOLVED CONTRACT GAP OF THE SAME
        #     CLASS and is Lake's to decide, not this deck's to pre-empt. Until it is ratified the
        #     honest position is to label nothing rather than to label it wrongly.
        #
        # (e) THE COUNT IS NOT LOST. It goes to the EXISTING server-side-only diagnostic channel --
        #     `Rails.logger` -- which is the same channel `I3ReadResult#reason` and
        #     `I2ReaderProcessClient#last_refusal` use for operator-facing detail that must not
        #     reach the wire (`i3_read_result.rb:59-62`, `i2_reader_process_client.rb:80`). No new
        #     channel is created and no new wire field is created. Operators keep the number; the
        #     caller is told nothing the contract has no words for.
        removed = atoms.length - filtered.length
        if removed.positive?
          Rails.logger.info(
            { atomspace_i3_acl_omission: { removed: removed, returned: filtered.length,
                                           store_returned: atoms.length } }.to_json
          )
        end

        # STORE's REAL omission/staleness/count metadata, forwarded when STORE sent it. Kept
        # strictly separate from the ACL figure logged above: one is the store's truncation, the
        # other is this deck's filtering, and conflating them would misattribute both.
        #
        # ==== `omitted` IS AUTHORIZED BEFORE EMISSION (the continuation leak this repairs)
        #
        # THE DEFECT. This call used to forward `omitted` UNCHANGED, immediately after the atom list
        # had been ACL-filtered above. STORE's `omitted.continue` carries ENTRY IDENTITIES -- the
        # `{key, digest}` candidates of the ambiguous-digest path (`i2_read.py:705-706`) and the
        # cursor's `after` / `participant` keys (`i2_read.py:697-699`) -- so an atom REMOVED from
        # `results` by `filter_by_read_auth` because the caller may not read its card STAYED
        # IDENTIFIABLE in the continuation. The caller could read the denied card's key text, and
        # therefore its existence, straight out of `omitted`. That is a read-permission oracle
        # around the back of the filter, and it defeats the non-oracle property every other path
        # on this surface is built to preserve.
        #
        # THE FIX. The SAME ACL used for the atom list is handed to the forwarder as an `authorize`
        # predicate, and any continuation carrying an identity this caller may not read causes the
        # WHOLE continuation to be dropped (see I3Envelope.forward_store_metadata for why the whole
        # list and not just the offending item). `bound` and `count` still travel: they name a
        # closed-enumeration category and an exact cardinality, neither of which identifies a card.
        #
        # THE PREDICATE MAPS A STORE KEY TEXT TO THE DECK'S OWN ACL. STORE identities are key texts
        # of the documented form `(Card <id>)` (`i2_reader_process_client.rb:579-585`
        # `participant_key_for`, the SAME function used to ADDRESS the store). The id is recovered
        # from that one documented form and run through `readable_source?` -- the existing
        # caller-scoped, default-deny check, not a second copy. Any text that is NOT that form
        # cannot be mapped to a card id, so it CANNOT be authorized and is denied: a link key, a
        # digest-shaped string or any future identity form all fail closed, which drops the
        # continuation rather than emitting an identity this deck was unable to check.
        Atomspace::I3Envelope.forward_store_metadata(
          payload, reading.payload, authorize: method(:store_identity_readable?)
        )

        # ====================================================================================
        # THE STRUCTURED STORE GRAPH, ADDED (the forwarding defect this repairs)
        # ====================================================================================
        #
        # (a) WHAT WAS LOST. `payload` above is `{"results" => [flat atoms]}` and NOTHING ELSE.
        #     That REDUCES STORE's structured answer to a flat Array<Atom>: STORE's real I2-09
        #     payload is `{"participant": {...}, "buckets": [...]}` and its real I2-03 payload is
        #     `{"entries": [...]}`, so the participant's own key/digest/label, every bucket's
        #     link-type and counts, and every entry's class and links were flattened away.
        #
        # (b) WHY THAT BROKE THE ONLY CONSUMER. `av-client/src/drawn-graph.mjs` ingests the drawn
        #     graph from `response.participant`, `response.buckets[]`, `response.entries[]`,
        #     `response.bucket`, `response.counts` and `response['self-links']`. It NEVER reads
        #     `results`. `ingestOpen` additionally REQUIRES `participant.key` and
        #     `participant.digest` to be Strings (it throws TypeError via `wireIdentity`
        #     otherwise). So the graph could not be ingested at all.
        #
        # (c) THIS IS ADDITIVE, DELIBERATELY. `results` is still emitted, byte-identical to
        #     before, so no previously-passing assertion regresses and `render_acl_empty`'s
        #     `{"results" => []}` non-oracle shape is untouched. The structured keys are ADDED
        #     beside it.
        #
        # (d) THE SAME ACL, NOT A SECOND ONE. The predicate handed to the projection is the SAME
        #     `store_identity_readable?` already used for continuation identities above -- the
        #     caller-scoped, default-deny check. The projection authorizes the participant's own
        #     key (denied -> NO structured graph at all) and every entry's key (denied -> that
        #     entry dropped whole, with its digest and links), and it coins no vocabulary to say
        #     so, which is what keeps a dropped entry indistinguishable from one STORE never sent.
        Atomspace::I3Envelope.project_store_graph(
          payload, reading.payload, authorize: method(:store_identity_readable?),
          unresolved_heads: declared_unresolved_heads(reading.envelope)
        )

        # ====================================================================================
        # THE STRUCTURED `participant.properties` MUST NOT BYPASS THE ATOM ACL.
        # ====================================================================================
        #
        # `filter_by_read_auth` filtered the ATOM list above, and on the `open` path every atom IS
        # one of STORE's `participant.properties` entries (`i2_reader_process_client.rb`
        # `atoms_from_properties` builds one Atom per property, carrying that property's STORE
        # `key`). The projection copies `participant` VERBATIM, so without this step the full
        # property list -- including properties whose atom the ACL had just removed -- would ride
        # out inside `participant` while being absent from `results`. That is the same
        # read-around-the-filter leak the `omitted` authorization closed, in a new place.
        #
        # THE RULE: the emitted property list contains EXACTLY the properties whose corresponding
        # atom SURVIVED the filter, matched on the property's own STORE `key`. Nothing is
        # re-authorized here and no second ACL is introduced -- the surviving atom set IS the
        # decision, and this only projects it.
        #
        # IF EVERY PROPERTY WAS FILTERED the `properties` KEY IS REMOVED rather than emitted as
        # `[]` -- UNLESS STORE ITSELF SENT AN EMPTY LIST, in which case STORE's own empty list is
        # preserved. The distinction matters: STORE's `[]` is a truthful statement that this
        # participant has no properties, while an ACL-emptied `[]` would assert the same thing
        # falsely about a participant that has properties this caller may not read.
        restrict_structured_properties!(payload, reading.payload, filtered)

        render_i3(reading, payload: payload)
      end

      # Keep only the structured properties whose ATOM survived `filter_by_read_auth`.
      # See the long note in #render_card_scoped for why. Mutates `payload`.
      def restrict_structured_properties!(payload, store_payload, filtered_atoms)
        participant = payload["participant"]
        return unless participant.is_a?(Hash)

        store_participant = store_payload.is_a?(Hash) ? store_payload["participant"] : nil
        store_properties = store_participant.is_a?(Hash) ? store_participant["properties"] : nil
        return unless store_properties.is_a?(Array)

        # STORE's own empty list is TRUTH and is preserved exactly as it came.
        if store_properties.empty?
          participant["properties"] = store_properties
          return
        end

        # The STORE keys of the atoms that SURVIVED the ACL. An atom with no `key` field cannot be
        # matched to a property and therefore authorizes none -- the safe direction.
        allowed = filtered_atoms.each_with_object({}) do |atom, acc|
          fields = atom.to_h
          key = fields[:key] || fields["key"]
          acc[key] = true if key.is_a?(String)
        end

        kept = store_properties.select do |prop|
          prop.is_a?(Hash) && prop["key"].is_a?(String) && allowed[prop["key"]]
        end

        if kept.empty?
          # ABSENT, NOT `[]`. An ACL-emptied list must not claim the participant has no properties.
          participant.delete("properties")
        else
          participant["properties"] = kept
        end
      end

      # Is the card named by a STORE key text readable BY THIS CALLER? Used to authorize
      # continuation identities before they may be emitted (see render_card_scoped).
      #
      # FAIL-CLOSED BY CONSTRUCTION. Only the one documented participant-key form is recognised --
      # `(Card <digits>)`, exactly what `participant_key_for` produces when ADDRESSING the store --
      # and the mapping itself is #card_id_from_store_key_text, the SAME single implementation the
      # subject-addressing `~k` path uses, so the two cannot disagree about which keys are
      # addressable. The ACL decision is delegated to `readable_source?`, the same caller-scoped
      # default-deny path `#open` and `#neighbours` gate on. Anything else (a link key, a bare
      # digest, a name, a nil, a non-String) returns false, because an identity this deck cannot
      # map to a card is an identity it cannot authorize, and an unauthorizable identity must never
      # reach the wire.
      #
      # NO ORACLE IS CREATED. The result is never rendered and never distinguishes anything for the
      # caller: it only ever REMOVES metadata. A caller cannot tell a denied continuation from a
      # store that sent no continuation at all.
      def store_identity_readable?(key_text)
        card_id = card_id_from_store_key_text(key_text)
        return false unless card_id

        readable_source?(card_id)
      rescue StandardError => e
        # An ACL check that RAISED has not authorized anything. Denying is the only safe reading.
        Rails.logger.warn("I3 continuation identity authorization failed: #{e.class}")
        false
      end

      # THE ACL-EMPTY ANSWER for an unreadable or absent source card.
      #
      # WHY IT IS NOT `render_card_scoped([])` ANY MORE: the old call passed a bare empty array into
      # the renderer, which produced a 200 with no envelope. Now that the envelope is mandatory and
      # must carry a REAL state triple, an unreadable source presents a genuine problem -- there is
      # no STORE read to take a triple from, because the backend was deliberately never touched.
      #
      # The resolution is to take the triple from STORE's I2-01 status, which is a STATE READ that
      # discloses nothing about the requested card: the epoch/position/read-at of the published
      # state are the same values every other caller sees. No card-scoped read happens, so no
      # existence or permission fact about the subject card is revealed. The shape is identical to
      # a card whose every atom was filtered, which is the non-oracle property this path requires.
      #
      # If STORE cannot supply a state at all, the response is the no-state envelope -- the same one
      # a genuinely unready backend gets -- which is honest and still not an oracle.
      #
      # THE NO-STATE OUTCOME IS PASSED EXPLICITLY (the defect this repairs). `acl_empty_reading`
      # returns a carrier with NO envelope when the status probe yields nothing, and
      # `I3Envelope.compose` RAISES Unrenderable on a carrier that has neither a STORE outcome nor
      # a caller-supplied one (i3_envelope.rb:111-112) -- deliberately, because defaulting an
      # outcome is how a failure becomes a success. Previously this call site supplied none, so the
      # request fell through the Unrenderable rescue into the non-envelope 503 that this whole round
      # exists to remove. The outcome is now named here instead, and `compose` stays fail-closed.
      def render_acl_empty
        reading = acl_empty_reading
        payload = reading.no_state? ? {} : { "results" => [] }
        render_i3(reading, payload: payload, outcome: no_state_outcome_for(reading))
      end

      # The I3-10 miss: outcome `unknown`, no payload (k8-draft-2.md:483 payload column "none").
      #
      # No `name` is echoed. The request string is not a resolved name, and the point of the
      # canonical-name rule is that only a name the framework actually resolved may be reported;
      # on a miss nothing was resolved, so nothing is named.
      def render_lookup_unknown
        reading = acl_empty_reading
        if reading.no_state?
          # EXPLICIT no-state outcome, for the same reason as render_acl_empty above: a carrier
          # with no envelope has no outcome of its own, and `compose` will not invent one.
          return render_i3(reading, payload: {}, outcome: no_state_outcome_for(reading))
        end

        render_i3(reading, payload: {}, outcome: "unknown")
      end

      # THE GOVERNING OUTCOME OVERRIDE for the two answers that never read the subject card.
      #
      # Returns nil whenever the carrier HOLDS A STORE ENVELOPE, so `compose` reads the outcome off
      # STORE's own validated envelope (i3_envelope.rb:111) and VIEW overrides nothing. That is the
      # case both for a stateful status answer (`ok`) AND for STORE's own `not ready`, which
      # `I3ReadPort.state_envelope` now carries through instead of discarding -- so the real store
      # answer is reported as the store's, not re-minted here.
      #
      # Returns `unavailable` ONLY when the carrier has NO envelope at all. The two no-state
      # outcomes are not interchangeable (`k8-draft-2.md:486-487`):
      #
      #   * `not ready`   -- "the store has no published, ready state". A STATEMENT BY THE STORE,
      #     and it is only ever emitted here by carrying STORE's own envelope (above).
      #   * `unavailable` -- the store "could not be reached or could not answer". This is exactly
      #     the no-envelope case: `store_state_envelope` yielded nil because the port is unwired,
      #     the channel is dead, the probe raised, or I2-01 came back malformed
      #     (`i2_reader_process_client.rb:417-429`, plus this controller's own rescue). In NONE of
      #     those did STORE answer about its state, so reporting `not ready` would be VIEW
      #     asserting a store condition it never observed. Admitting it could not be reached is
      #     the only honest option.
      #
      # The distinction is NOT an oracle: both render the same all-null-triple envelope, and
      # neither depends on the subject card, the caller's permissions, or whether the card exists.
      def no_state_outcome_for(reading)
        return nil if reading.envelope

        "unavailable"
      end

      # A reading that carries ONLY STORE's published state, obtained from I2-01, with no
      # card-scoped read. Used by the two non-oracle answers above.
      #
      # EVERY FAILURE BECOMES NO-STATE, NOT A SUCCESS DEFAULT. A missing, malformed or unready
      # status answer yields I3ReadResult.no_state, which the renderer turns into the governing
      # `not ready` envelope with the three nulls. Nothing is defaulted to `ok`.
      def acl_empty_reading
        envelope = store_state_envelope
        return Atomspace::I3ReadResult.no_state(reason: "no published state") if envelope.nil?

        Atomspace::I3ReadResult.new(envelope: envelope)
      end

      # STORE's current state envelope, from the port's own status probe. nil when unavailable.
      def store_state_envelope
        return nil unless Atomspace::I3ReadPort.respond_to?(:state_envelope)

        Atomspace::I3ReadPort.state_envelope
      rescue StandardError => e
        Rails.logger.warn("I3 state envelope unavailable: #{e.class}")
        nil
      end

      # ================================================================================================
      # THE SHARED, CONTRACT-CORRECT RENDERER. Every I3 read answer goes through here.
      #
      # It emits the K8 §5.2 envelope AT THE TOP LEVEL -- `outcome`, `epoch`, `position`, `read-at`,
      # `schema-version`, `limits` -- then the endpoint payload. That shape is what the authoritative
      # client parser requires (av-client/src/demo/live-bridge.mjs:762-795 `checkI3Body`), and the
      # previous `{results:, _meta:}` body failed its very first assertion by having no top-level
      # `outcome` at all.
      #
      # `_meta` IS PRESERVED, as an ADDITIONAL key. It is not part of K8's envelope, but it carries
      # the fixture/live provenance stamp (`data_origin`) that makes a fixture payload impossible to
      # present as live data, and the client ignores unknown keys. Dropping it to be minimal would
      # remove a safety property for no contract gain.
      #
      # STATUS IS 200. A `not ready` / `unavailable` OUTCOME is an in-band answer, not a transport
      # failure: the client classifies any `status >= 500` as `backend-error` BEFORE parsing
      # (live-bridge.mjs:821), so a 503 would make the outcome invisible and the honest refusal
      # unreadable. The pre-authorization and backend-condition 503s elsewhere in this controller are
      # UNCHANGED -- they are refusals and configuration faults, which K8 §5.1 :289-291 puts outside
      # the outcome set entirely.
      def render_i3(reading, payload: {}, outcome: nil)
        body = Atomspace::I3Envelope.compose(
          result: reading, profile: store_profile_for_request, payload: payload, outcome: outcome
        )
        body["_meta"] = i3_meta
        render json: body
      rescue Atomspace::I3Envelope::Unrenderable => e
        # A reading that cannot be rendered conformantly is a BACKEND CONTRACT failure, reported
        # through the EXISTING 503 path. It is never degraded into a success body with invented
        # metadata -- which is the whole point of having this rescue instead of a fallback.
        Rails.logger.error("I3 envelope unrenderable: #{e.message}")
        render_unavailable("i3_envelope_contract_violation")
      end

      # STORE's `schema-version` + `limits`, read once per request and memoized.
      #
      # Memoized because all three handlers render exactly one body per request, so this is one
      # extra I2-01 per request at most -- and NOT a per-render re-read, which would let two
      # fields of one response come from two different store states.
      def store_profile_for_request
        return @store_profile_for_request if defined?(@store_profile_for_request)

        @store_profile_for_request =
          begin
            Atomspace::I3ReadPort.store_profile
          rescue StandardError => e
            Rails.logger.warn("I3 store profile unavailable: #{e.class}")
            nil
          end
      end

      # STORE's OWN declared unresolved-target heads, for the structured projection.
      #
      # WHY THIS IS READ FROM STORE AND NOT WRITTEN DOWN HERE. K8 §5.6 N04 gives unresolved
      # targets a distinct rule -- one "belongs to its one link, has no neighbourhood, and is never
      # shared between links" (`k8-draft-2.md:630-631`) -- so the projection must know WHICH heads
      # are unresolved-target constructors to apply it. But `Card` and `Wanted` are NOT store
      # constants: STORE's participant heads are RUNTIME-DECLARED, so hardcoding `Wanted` would be
      # this deck inventing store vocabulary and would silently mis-handle a deployment that
      # declares a different one. The set therefore comes from STORE's own I2-07 declarations.
      #
      # FAIL CLOSED AND MEMOIZED. Any failure, or a port that does not expose declarations, yields
      # `[]` -- and with an empty set EVERY non-Card position is denied exactly as before, so the
      # permissive direction is unreachable without STORE's own declaration. Memoized per request
      # so one response cannot see two different declaration sets.
      #
      # BOUND TO THE STATE BEING PROJECTED, and this is the part that was missing. Memoization
      # stops a single response seeing two declaration sets, but it does NOT establish that the
      # one set it does see describes the SAME store state as the reading. I2-07 is a separate
      # round trip: between the neighbours read and the declarations read, STORE may have
      # reprojected, so an `Unresolved` head declared in a LATER state could authorize an
      # unresolved target inside an EARLIER reading -- an authorization decision taken from a
      # state the projected data does not come from.
      #
      # So the declarations' own envelope must agree with the reading's on BOTH coordinates:
      #
      #   * `epoch` -- the state identity. A different epoch is a different projection outright.
      #   * `position` -- the point within that epoch. STORE's cursor rules treat position
      #     movement as material (`i2_read.py` `_check_cursor` answers `reload` when a retained
      #     position falls outside its window), so epoch equality alone is not state equality.
      #
      # This is the SAME binding `merge_i2_03_participant_address` already enforces on the I2-02
      # enrichment, applied to the authorization dependency that lacked it. A mismatch, a missing
      # envelope, or an unreadable reading envelope yields `[]` -- NO exception granted -- which
      # denies the unresolved target rather than admitting it on unverifiable grounds.
      # @param reading_envelope [Hash, nil] the envelope of the reading being projected.
      def declared_unresolved_heads(reading_envelope = nil)
        return @declared_unresolved_heads if defined?(@declared_unresolved_heads)

        @declared_unresolved_heads =
          begin
            impl = Atomspace::I3ReadPort.impl
            if impl.respond_to?(:declarations)
              envelope, payload = impl.declarations
              if declarations_describe_same_state?(envelope, reading_envelope)
                Atomspace::I3Envelope.unresolved_heads_from_declarations(payload)
              else
                Rails.logger.warn(
                  "I3 declarations rejected: they do not describe the reading's state"
                )
                []
              end
            else
              []
            end
          rescue StandardError => e
            Rails.logger.warn("I3 declarations unavailable: #{e.class}")
            []
          end
      end

      # Do STORE's declarations describe the SAME state as the reading being projected?
      #
      # DEFAULT-DENY ON EVERY UNCERTAINTY: a nil or non-Hash envelope on either side, a blank
      # epoch, or a non-Integer position answers false. Nothing is compared loosely and no
      # coordinate is defaulted -- an absent coordinate is a comparison this deck cannot make,
      # which means no exception is granted.
      def declarations_describe_same_state?(declarations_envelope, reading_envelope)
        return false unless declarations_envelope.is_a?(Hash)
        return false unless reading_envelope.is_a?(Hash)

        d_epoch = declarations_envelope["epoch"]
        r_epoch = reading_envelope["epoch"]
        return false unless d_epoch.is_a?(String) && !d_epoch.empty?
        return false unless r_epoch.is_a?(String) && !r_epoch.empty?
        return false unless d_epoch == r_epoch

        d_position = declarations_envelope["position"]
        r_position = reading_envelope["position"]
        return false unless d_position.is_a?(Integer) && !d_position.is_a?(TrueClass)
        return false unless r_position.is_a?(Integer) && !r_position.is_a?(TrueClass)

        d_position == r_position
      end

      # TYPE-VALIDATED address extraction for #lookup.
      #
      # The previous check tested only PRESENCE of key/digest, never their DECLARED TYPES. The
      # port documents the answer as `{"key" => String, "digest" => String}`
      # (i3_read_port.rb:90-91), and #lookup puts both values on the wire as the authoritative
      # backend address. A non-Hash answer, or a key/digest that is an Integer / Array / Hash /
      # nil, is a CONTRACT VIOLATION: rendering it would emit a partial or wrongly-typed address
      # that a caller reads as authoritative.
      #
      # Fails closed through the EXISTING AddressUnavailable -> 503 backend_digest_unavailable
      # path (render_address_unavailable), identical to the blank case, so a malformed address is
      # reported as the same BACKEND condition and is never downgraded to `unknown`.
      #
      # NO DIGEST IS EVER COMPUTED OR SYNTHESISED HERE -- VIEW is forbidden to produce one
      # deck-side (adapter.py:1473-1476). The only outcomes are the backend's own verbatim pair or
      # a refusal.
      # STRICT MAPPING TYPE FIRST, and this is the load-bearing part.
      #
      # The previous check was `respond_to?(:[])`, which does NOT establish a mapping. Ruby
      # Strings answer `[]` with SUBSTRING SEARCH, so the malformed single-string address
      # "key digest" satisfied every subsequent check:
      #   "key digest"["key"]    => "key"      (a String, non-blank)
      #   "key digest"["digest"] => "digest"   (a String, non-blank)
      # and #lookup rendered `found: true` with an address EXTRACTED FROM MALFORMED INPUT --
      # a fabricated-looking authoritative address that no backend ever issued. Arrays answer
      # `[]` too (with an index), so they were likewise admitted up to a TypeError.
      #
      # The port documents the answer as a Hash of {"key" => String, "digest" => String}
      # (i3_read_port.rb:90-91), so the DECLARED MAPPING TYPE is required before any extraction
      # is attempted. A String, Array, Integer, nil or bare atom is a CONTRACT VIOLATION and
      # fails closed on the typed path below -- never a success, never a generic 500.
      # @return [Array(String, String)] the validated [key, digest].
      def validated_address_fields(address)
        raise Atomspace::I3ReadPort::AddressUnavailable, "backend_digest_unavailable" unless address.is_a?(Hash)

        key = address["key"] || address[:key]
        digest = address["digest"] || address[:digest]
        # STRING-TYPED and non-blank, both of them. `.blank?` alone would accept 0 or a Hash.
        unless key.is_a?(String) && !key.blank? && digest.is_a?(String) && !digest.blank?
          raise Atomspace::I3ReadPort::AddressUnavailable, "backend_digest_unavailable"
        end

        [key, digest]
      end

      # NOTE: `render_global` and `render_unknown` HAVE BEEN REMOVED.
      #
      # Both emitted the non-conforming Rails-shaped `{results:, _meta:}` body with NO top-level
      # `outcome` -- the exact shape av-client's `checkI3Body` (live-bridge.mjs:762-795) rejects on
      # its first assertion. They are deleted rather than left unused so the wrong shape cannot be
      # reintroduced by a future handler picking up a convenient-looking renderer. Their
      # replacements are `render_i3` (the single shared contract-correct renderer) and
      # `render_lookup_unknown` (the K8 §5.5 lookup-miss rule).
      #
      # `#health` is unaffected: it renders its own 501 capability-missing body, which is a
      # REFUSAL and therefore outside K8's outcome set (k8-draft-2.md:289-291).

      # Provenance stamp. data_origin comes from the bound port, so a FIXTURE payload is labelled
      # "fixture" on the wire and can never be presented as live data.
      def i3_meta
        { surface: "i3", data_origin: Atomspace::I3ReadPort.origin }
      end

      # DUAL-MODE PRINCIPAL GATE. Exactly ONE of two authentication mechanisms establishes the
      # caller, and BOTH end at the same place: a real, non-service user account card, used as
      # the subject of every subsequent card touch.
      #
      #   SESSION MODE (the browser path) -- tried FIRST, and only when the request carries NO
      #   Authorization header at all. An existing same-origin Decko session identifies the
      #   caller; no secret is sent to or accepted from the browser.
      #
      #   TOKEN MODE (the pre-existing MCP path) -- unchanged, byte for byte, below.
      #
      # WHY "NO Authorization HEADER" IS THE DISCRIMINATOR AND NOT A FALLBACK CHAIN: if a
      # presented token is invalid, that is an AUTHENTICATION FAILURE and must be refused as one.
      # Falling back to the session would let a caller who presents a bad/expired/forged token be
      # silently answered as whoever happens to be signed in in that browser -- a confusion of
      # principals. So the two modes are mutually exclusive and the choice is made on the
      # REQUEST SHAPE, before either is evaluated.
      def require_user_principal!
        return require_session_principal! if session_mode?

        require_token_principal!
      end

      # SESSION MODE is selected only in the TOTAL ABSENCE of an Authorization header. A present
      # header -- even a malformed, blank or non-Bearer one -- stays on the token path so it is
      # refused there rather than quietly downgraded to the session principal.
      #
      # THIS PREDICATE IS NOW LOAD-BEARING TWICE: it dispatches #require_user_principal! AND it is
      # the condition on `skip_before_action :authenticate_mcp_request!` above. Both uses call THIS
      # method, so the skip and the dispatch cannot disagree -- a request can never have the parent
      # Bearer gate skipped and then be routed to the token principal (which would self-inflict a
      # 401), nor have the gate run and then be routed to the session principal (which would be a
      # fallback from a failed token).
      #
      # `.nil?`, NOT `.blank?`, AND THE DIFFERENCE IS DELIBERATE. `blank?` is true for "" and for
      # "   ", so a request that PRESENTS an empty Authorization header would have been treated as
      # session mode -- contradicting the paragraph above and making "is a header present?" and
      # "does the skip apply?" two different questions. `nil?` is true only when the header is
      # genuinely absent from the request, which is exactly the browser case (a user agent that
      # was given no credential sends no header). Any header the caller actually set, including a
      # blank one, therefore goes to the token path and is refused there by
      # `extract_token_from_header` -> render_unauthorized("Missing authorization token")
      # (base_controller.rb:33-34, :52-56).
      #
      # OPERATIONAL CONSEQUENCE, stated because it is a real tradeoff and not a free win: if a
      # reverse proxy in front of this deck INJECTS an empty `Authorization:` header onto browser
      # requests, those requests will be refused 401 as token requests rather than falling through
      # to the session. That is the fail-closed direction (a refusal, never an unauthenticated
      # read), but it is a deployment condition to check before relying on the browser path.
      def session_mode?
        request.headers["Authorization"].nil?
      end

      # THE SESSION PRINCIPAL. Established from the FRAMEWORK's session, never from the request.
      #
      # REFUSES, never falls back: no session / anonymous / non-account / service account /
      # unresolvable account all end in a refusal. There is no anonymous-but-permissive read and
      # no bot subject anywhere on this path.
      def require_session_principal!
        account = session_account

        unless account
          return render json: { error: "principal_unresolved", _meta: DENIED_META },
                        status: :unauthorized
        end

        # The SAME canonical-identity service-account exclusion as the token path. A service
        # account must not be usable as a browser principal either, and the alias-safe id
        # comparison is what makes that stick (see #service_account?).
        if service_account?(account)
          return render json: { error: "principal_not_permitted", _meta: DENIED_META },
                        status: :forbidden
        end

        # Fill the SAME ivars the rest of the controller and AtomspaceReadFilter already consume,
        # so no downstream code has to know which mechanism authenticated the caller.
        @current_mcp_account = account
        @current_mcp_payload = nil
        # ROLE FROM THE FRAMEWORK, not the request: persisted role membership via
        # Card::Auth.current_roles (card/lib/card/auth/current.rb:28-33).
        @current_mcp_role = nil
        @session_authenticated = true
        nil
      end

      # Resolve the signed-in account THROUGH THE FRAMEWORK'S OWN METHODS.
      #
      # VERSION NOTE, stated because it bounds what the citations prove: the Gemfile.lock pins
      # `card (1.110.0)` / `decko (0.20.0)`, while the decko source checkout available on this
      # host is card/VERSION 0.19.1 -> card gem 1.109.1 (Cardio::Version.card_release,
      # card/lib/cardio/version.rb:13-15). Every line cited here was read from that 1.109.1
      # source. The session mechanism it documents (session_user_key -> card id -> account?) is
      # long-standing, but a 1.110.0 change to it would NOT be reflected in these citations, and
      # the pinned gem is NOT INSTALLED on this host so it could not be read.
      #
      # WHY `Card::Env.reset self` FIRST: `Card::Env.session` reads `request&.session` off
      # `Env.controller` (card/lib/card/env.rb:17-23). This is an ActionController::API
      # controller, so Decko's own `setup` (decko/lib/card_controller/rest.rb:31-35) never ran and
      # `Env.controller` is either nil or -- worse, under a threaded/preloaded server -- STALE
      # FROM A PREVIOUS REQUEST. Binding Env to THIS controller is what makes
      # `signin_with_session` read THIS request's cookie rather than another request's.
      # `clear_mcp_state_after_request` tears it back down in an ensure block.
      #
      # WHY `signin_with_session` AND NOT A HAND-ROLLED SESSION READ: it is the framework's own
      # resolution (card/lib/card/auth/current.rb:59-63) and it carries the check that matters --
      # `card_id = nil unless card_id.card&.account?` -- so a session holding a non-account card
      # id (or a deleted one) yields Anonymous rather than a usable principal. Re-implementing it
      # here would be a second copy of an authentication decision.
      #
      # @return [Card, nil] the signed-in, live, type:User account card; nil when there is no
      #   usable signed-in principal, for ANY reason, indistinguishably.
      def session_account
        Card::Env.reset(self)
        Card::Auth.signin_with
        # FIRST GUARD: the framework's own signed-in predicate, which is exactly
        # `current_id != AnonymousID` (card/lib/card/auth/current.rb:45-47). STRICT `== true`, not
        # truthiness, so a framework that ever returned a non-boolean cannot open the gate.
        return nil unless Card::Auth.signed_in? == true

        card = Card::Auth.current_card
        return nil unless card && !card.trash && card.id

        # SECOND AND THIRD GUARDS, INDEPENDENT OF THE FIRST, and they are here because the first
        # one alone is only as strong as the deck's Anonymous card configuration.
        #
        # `Card::Auth.current_card` is `Card[current_id]` (current.rb:21-25), so when current_id is
        # AnonymousID it returns the REAL, PERSISTED Anonymous card -- not nil. In the stock deck
        # that card is id 201 with type_id 2 / codename `basic`
        # (decko/mod/defaults/data/fixtures/real/cards.yml:3712-3730, and card id 2 is RichText at
        # :24-40), so the type check below happens to refuse it as a side effect. But that is an
        # ACCIDENT OF CONFIGURATION, not a guarantee: Anonymous's type is editable, and a deck whose
        # Anonymous card had been retyped to User would have had NOTHING but the signed_in? line
        # standing between an unauthenticated request and a served response.
        #
        # So the identity is refused EXPLICITLY on two further framework facts that no deck
        # configuration can invert:
        #   * the id must not BE AnonymousID; and
        #   * `account?` must be true -- it is defined false on Anonymous
        #     (decko/mod/account/set/self/anonymous.rb:7-9) and true only for a real account holder
        #     (mod/account/set/abstract/account_holder.rb), and it is the SAME predicate the
        #     framework's own `signin_with_session` uses to reject a non-account session id
        #     (current.rb:59-63).
        # Any ONE of these three independently refuses an anonymous caller.
        return nil if card.id == Card::AnonymousID
        return nil unless card.respond_to?(:account?) && card.account? == true
        return nil unless card.type_id == Card::UserID

        card
      rescue StandardError => e
        # A framework failure during authentication is NOT a principal. Logged server-side only;
        # the caller receives the same indistinguishable refusal.
        Rails.logger.warn("I3 session principal resolution failed: #{e.class}")
        nil
      end

      # THE PRE-EXISTING TOKEN PRINCIPAL GATE, unchanged in substance.
      def require_token_principal!
        # Re-evaluating BaseController moves its filters behind these, so never rely on their order.
        authenticate_mcp_request! unless @current_mcp_payload
        return if performed?

        sub = @current_mcp_payload["sub"]
        unless sub.to_s.start_with?("user:")
          return render json: { error: "principal_not_permitted", _meta: DENIED_META }, status: :forbidden
        end

        account = user_account_for(sub)
        # A SERVICE ACCOUNT NAMED AS THE SUBJECT must be refused BEFORE the id comparison. The
        # service accounts are real type:User cards, so a token with sub "user:mcp-admin" resolves
        # through find_mcp_account's DIRECT-SUBJECT branch (base_controller.rb:73-79) -- the role
        # fallback is never entered and the ids MATCH, so the comparison below would ADMIT it and
        # the request would proceed as the administrative service account. Reuses the existing
        # principal_not_permitted code so this adds no new wire vocabulary.
        #
        # BOTH SIDES ARE CHECKED ON CANONICAL IDENTITY. `account` is the card the TOKEN SUBJECT
        # resolves to and @current_mcp_account is what BASECONTROLLER resolved; either can be a
        # service account independently (the subject via the direct branch, BaseController's via
        # the role fallback), and a separator/case alias of a configured name resolves to the
        # same card as the canonical spelling. Comparing ids closes both doors at once.
        if service_account?(account) || service_account?(@current_mcp_account)
          return render json: { error: "principal_not_permitted", _meta: DENIED_META }, status: :forbidden
        end

        # The resolved account must BE the token's subject. If BaseController fell back to a service
        # account, the ids differ and this refuses -- that is the fallback-defeating check.
        return if account && account.id == @current_mcp_account&.id

        render json: { error: "principal_unresolved", _meta: DENIED_META }, status: :unauthorized
      end

      # CANONICAL-IDENTITY service-account exclusion. Compares PERSISTED CARD IDS, not strings.
      #
      # WHY STRING COMPARISON IS WRONG HERE: Decko names are not identified by display-string
      # equality, case-insensitive or otherwise. Cardname#simple_key (cardname.rb:101-116)
      # underscores, collapses every run of non-key characters to "_" and stable-keys each part,
      # so "mcp_admin", "mcp-admin", "MCP Admin" and "mcp--admin" ALL share ONE key and resolve
      # to the SAME CARD. A configured MCP_ADMIN_NAME="mcp_admin" therefore resolves the stored
      # card named "mcp-admin" through BaseController's `Card[account_name]`
      # (base_controller.rb:91), while `casecmp?` compared "mcp_admin" against "mcp-admin",
      # found them unequal, and ADMITTED the administrative service identity.
      #
      # So resolution goes through THE SAME `Card[...]` lookup BaseController uses, and identity
      # is decided on `#id` -- the framework's own canonical identity -- which is immune to every
      # separator, case and whitespace alias by construction. A configured name that resolves to
      # nothing contributes no id and so can never match.
      #
      # @return [Boolean] true when this account IS one of the configured service accounts.
      def service_account?(account)
        return false unless account&.id

        service_account_ids.include?(account.id)
      end

      # The configured service accounts resolved to persisted ids, exactly as
      # BaseController#find_mcp_account resolves them (base_controller.rb:84/:86/:88/:91) --
      # ENV value when set, otherwise the SAME default string. Resolution failures are dropped,
      # never guessed.
      def service_account_ids
        service_account_names.filter_map do |svc|
          card = Card[svc]
          card&.id
        end
      end

      def service_account_names
        [
          ENV.fetch("MCP_USER_NAME", "mcp-user"),
          ENV.fetch("MCP_GM_NAME", "mcp-gm"),
          ENV.fetch("MCP_ADMIN_NAME", "mcp-admin")
        ].map { |n| n.to_s.strip }.reject(&:empty?)
      end

      # A live, non-trashed card of type User, resolved from the token's OWN subject.
      def user_account_for(sub)
        name = sub.delete_prefix("user:").sub(/\+\*account\z/, "")
        card = Card[name]
        card if card && !card.trash && card.type_id == Card::UserID
      end

      # Namespaced gate. mcp:atomspace:read does NOT satisfy it and is not widened by it.
      #
      # TWO AUTHORITIES, one per authentication mechanism, and NEITHER is request-asserted:
      #
      #   TOKEN MODE: the token's `scope` claim, exactly as before. Scopes are minted server-side
      #   from an ENV allowlist of named users (atomspace_grants.rb:62-64), never self-selected.
      #
      #   SESSION MODE: the caller's PERSISTED DECKO ROLE MEMBERSHIP. A browser session carries no
      #   scope claim and MUST NOT be allowed to assert one (a `?scope=` parameter would be a new
      #   wire surface AND a self-asserted authority -- both forbidden), so entitlement is read
      #   from the framework: `Card::Auth.current_roles` is
      #   `[:anyone_signed_in] + Set::Self::Role.role_ids(current_id)`
      #   (card/lib/card/auth/current.rb:28-33), i.e. actual role-card membership.
      #
      # THE SESSION ENTITLEMENT IS AN EXPLICIT ALLOWLIST, DEFAULT-DENY. It is NOT "any signed-in
      # user": `:anyone_signed_in` is unconditionally present in current_roles for every signed-in
      # caller, so accepting it would make the gate vacuous. The deployment names the entitled
      # role in I3_SESSION_READ_ROLE; if that is unset or names no role the caller holds, the
      # request is REFUSED. No new access grant and no new role is created by this code -- an
      # EXISTING role is named as the required one.
      def require_i3_read_scope!
        return if @session_authenticated ? session_role_entitled? : token_scopes.include?(McpApi::AtomspaceGrants::I3_READ_SCOPE)

        render json: { error: "forbidden",
                       detail: "#{McpApi::AtomspaceGrants::I3_READ_SCOPE} scope required",
                       _meta: DENIED_META }, status: :forbidden
      end

      # FRAMEWORK-READ role entitlement for the session path. Default-deny at every step:
      # unconfigured -> false; vacuous -> false; role not held -> false; framework failure -> false.
      #
      # THE DECISION THIS SETTLES (the second open question in this surface). A browser session
      # carries NO token and therefore NO `scope` claim, so `mcp:i3:read` cannot be derived the way
      # the token path derives it. Three options were available and two are refused outright:
      #   (a) accept any signed-in caller -- REFUSED, it is not an entitlement decision at all;
      #   (b) let the request name its own scope/role (`?scope=`, a header) -- REFUSED twice over:
      #       self-asserted authority, and new wire surface (O25 is UNAUTHORIZED);
      #   (c) read PERSISTED ROLE MEMBERSHIP from the framework -- ADOPTED.
      # So entitlement is `Card::Auth.current_roles` (card/lib/card/auth/current.rb:28-33, i.e.
      # `[:anyone_signed_in.cardname] + Set::Self::Role.role_ids(current_id).map(&:cardname)`,
      # where role_ids is actual role-card membership, decko/mod/account/set/self/role.rb:8-14)
      # intersected against ONE role named by the deployment in I3_SESSION_READ_ROLE.
      #
      # THIS CODE CREATES NOTHING AND GRANTS NOTHING. It mints no token, creates no role, writes no
      # card, adds no ENV default, and adds no wire parameter. It NAMES an EXISTING role as the
      # required one and refuses everyone else. Shipping it with I3_SESSION_READ_ROLE unset leaves
      # the browser path CLOSED to every caller, which is the intended default: granting access is a
      # separate, human, deployment-time act (set the variable to an existing role), not something
      # this change performs.
      #
      # VACUOUS CONFIGURATIONS ARE REJECTED, not honoured. `:anyone_signed_in` is present in
      # current_roles for EVERY signed-in caller, so configuring it (under any spelling) would turn
      # this gate into option (a) by the back door and silently entitle the whole internet's worth
      # of signed-up accounts. A deployment that names it is treated as a CONFIGURATION ERROR and
      # the request is REFUSED -- fail-closed, logged for the operator, never honoured. Same for
      # `*all` / `Anyone`, the framework's everyone-sets.
      #
      # Comparison is on Decko's own CANONICAL KEY, not a display string, for exactly the reason
      # #service_account? compares ids: Cardname collapses separators and case
      # (cardname-0.19.1/lib/cardname.rb:72, :101-116), so "RDA Member", "rda_member" and
      # "rda-member" are ONE role and a literal string comparison would miss the alias the
      # deployment actually configured.
      def session_role_entitled?
        configured = ENV.fetch("I3_SESSION_READ_ROLE", "").to_s.strip
        return false if configured.empty?

        required = Card::Name.new(configured).key
        return false if required.to_s.empty?

        if VACUOUS_SESSION_ROLE_KEYS.include?(required)
          Rails.logger.error(
            "I3_SESSION_READ_ROLE names a vacuous everyone-role; refusing (fail-closed)"
          )
          return false
        end

        # `role&.key`: current_roles maps codenames through Card::Codename.name (current.rb:32),
        # which yields nil for a codename this deck does not define. A single nil entry must not
        # raise into the rescue below and thereby deny an otherwise-entitled caller.
        Card::Auth.current_roles.any? { |role| role&.key == required }
      rescue StandardError => e
        Rails.logger.warn("I3 session role resolution failed: #{e.class}")
        false
      end

      # Fail-closed readiness. Reuses the I3 port's Result (an Atomspace::MirrorReadiness::Result),
      # so ONE distinct reason string per failure mode, and an unwired port is not-ready by default.
      # Health is exempt: it is a static capability refusal that reveals no backend state.
      #
      # ==== THE BODY IS NOW THE `not ready` ENVELOPE, NOT A BARE 503 (the defect this repairs)
      #
      # This filter used to render
      #   {"error":"i3_backend_not_ready","reason":<reason>,"_meta":{...}}  503
      # which has NO top-level envelope and which the ONLY consumer that exists PROVABLY CANNOT
      # READ: `live-bridge.mjs:821` `classifyHttp` maps any `status >= 500` to `backend-error` and
      # the caller throws LiveTransportFailed BEFORE `checkI3Body` ever runs. So the honest
      # readiness answer was invisible. K8 §5.2 `:300` is EXACT -- "Every response, including every
      # failure that is not a refusal, begins with" the six-field envelope -- and §5.1 `:289-291`
      # scopes "refusal" to a K9 ACCESS decision only ("Refusal is K9's, not K8's"), so an unready
      # backend is NOT a refusal and owes the caller an envelope. `not ready` is its enumerated
      # outcome (`:486`), and it is one of the two that legally carry the all-null triple
      # (`:495-498`). It is therefore rendered THROUGH THE SAME SHARED RENDERER as every other
      # answer on this surface -- `render_i3` -> `Atomspace::I3Envelope.compose` -- so there is
      # still exactly one envelope composer here and this path cannot drift from the others.
      #
      # ==== THE GATE ORDER IS UNCHANGED, AND THAT IS LOAD-BEARING
      #
      # This is still the THIRD before_action, after `require_user_principal!` and
      # `require_i3_read_scope!` (:278-280 are untouched). An unauthorized caller halts earlier and
      # therefore STILL never receives a readiness signal -- the readiness envelope is emitted only
      # to a caller who already passed principal + scope. The class-3 Observability alert is kept
      # for the same reason it was always safe here: this code runs only after authorization.
      def require_i3_backend_ready!
        return if action_name == "health"

        result = Atomspace::I3ReadPort.readiness
        # STRICT `true`, not truthiness. MirrorReadiness::Result#ready? (mirror_readiness.rb:33-35)
        # returns the struct member UNCOERCED, so ready: "false" or ready: 0 is TRUTHY in Ruby and a
        # bare `if result.ready?` would proceed as READY on a malformed answer. Only a real boolean
        # true opens the gate.
        return if result.ready? == true

        # NOT EVERY NON-READY RESULT MEANS "THE STORE HAS NO STATE" (the defect this repairs).
        # See #readiness_outcome_for: the reason decides which of the two no-state outcomes is the
        # TRUE statement, and an unrecognised reason fails closed to `unavailable`.
        if readiness_outcome_for(result.reason) == "not ready"
          render_not_ready_envelope(result.reason)
        else
          render_unavailable_envelope(result.reason)
        end
      end

      # WHICH NO-STATE OUTCOME IS TRUE OF A NON-READY READINESS RESULT.
      #
      # ==== THE DEFECT THIS REPAIRS
      #
      # `require_i3_backend_ready!` used to end with a bare `render_not_ready_envelope(result.reason)`,
      # so EVERY non-ready readiness verdict was reported as the outcome `not ready` -- which
      # `k8-draft-2.md:486` defines as "no published state can be read yet (bootstrap, rebuild)".
      # That is an ASSERTION THAT THE STORE ANSWERED and that its answer was "I have no state".
      # Most of the reasons that reach here say no such thing:
      #   * `i3_read_port.rb:72`  -- NO READER IS BOUND AT ALL; nothing was asked of any store.
      #   * `i3_read_port.rb:76`, `:83` -- the bound impl's readiness answer was MALFORMED.
      #   * `i3_read_port.rb:88`  -- the readiness PROBE ITSELF RAISED.
      #   * `i2_reader_process_client.rb:232-237` -- the child DID NOT ANSWER IN TIME, the CHANNEL
      #     IS DEAD, or the frame was unreadable.
      # In none of those did STORE state anything about its published state, so `not ready` was a
      # FALSE STATEMENT about the store. `k8-draft-2.md:487` has the outcome that is true of them:
      # `unavailable` -- "the store could not be reached or could not answer".
      #
      # ==== THE DECISION IS ON THE REASON, NOT A GUESS
      #
      # Both lists below are EXPLICIT and every member is a reason string that EXISTS in this
      # codebase today, cited to its definition. Nothing is inferred from the Result object's shape,
      # from the bound impl's class, or from whether `@impl` happens to be set at render time.
      #
      # ==== THE DEFAULT IS `unavailable`, DELIBERATELY (fail closed)
      #
      # `not ready` is reached ONLY by an explicit allowlist of reasons in which THE STORE ITSELF
      # reported on its own state. Anything else -- including a reason this method does not
      # recognise -- is reported as `unavailable`. That direction is the fail-closed one because the
      # two claims are NOT equally strong: "the store answered and it has no state" is a positive
      # factual claim ABOUT THE STORE, while "the store could not be reached or could not answer"
      # is an admission about THIS DECK's own knowledge. If the classification is wrong, under-
      # claiming is honest and over-claiming is a lie, so an unknown reason must never be allowed
      # to manufacture a statement about the store. An unclassified reason is additionally LOGGED
      # for the operator, so a newly-introduced reason string is visible rather than silently
      # absorbed by the default.
      #
      # ==== WHAT IS *NOT* CHANGED
      #
      # Both branches stay HTTP 200 with the three nulls PRESENT, keep `reason` as a post-envelope
      # sibling, keep `_meta` (so `data_origin` is "unavailable" whenever nothing is bound, exactly
      # as `i3_read_port.rb:93-98` already decides it -- this method does not touch provenance), and
      # keep the class-3 Observability alert. The before_action chain ORDER is untouched: this still
      # runs THIRD, after `require_user_principal!` and `require_i3_read_scope!`, so no readiness
      # signal of EITHER kind reaches an unauthorized caller.
      #
      # @return [String] "not ready" or "unavailable" -- always one of the two, never nil.
      def readiness_outcome_for(reason)
        text = reason.to_s
        return "not ready" if READINESS_STORE_ANSWERED_REASONS.include?(text)

        unless READINESS_UNREACHABLE_REASONS.include?(text) ||
               text.start_with?(READINESS_PROBE_ERROR_PREFIX)
          Rails.logger.warn(
            "I3 readiness reason #{text.inspect} is unclassified; reporting `unavailable` (fail closed)"
          )
        end

        "unavailable"
      end

      def token_scopes
        ((@current_mcp_payload && @current_mcp_payload["scope"]) || "").split
      end

      def render_bad_request(reason)
        render json: { error: "bad_request", reason: reason, _meta: i3_meta }, status: :bad_request
      end

      def render_invalid_request(error)
        render json: { error: "bad_request", reason: error.message, _meta: i3_meta }, status: :bad_request
      end

      def render_port_unwired(error)
        # The exception's CLASS goes to the server-side-only log, exactly as every sibling rescue
        # on this controller does (`:592`, `:696`, `:1322`, `:1419`). The class name is operator
        # detail and never reaches the wire: the rendered body is still the fixed enumerated
        # `unavailable` envelope with STORE's own reason sibling, derived from nothing here.
        Rails.logger.warn("I3 read port unwired: #{error.class}")
        render_unavailable_envelope(Atomspace::I3ReadPort::UNWIRED_REASON)
      end

      # THE ENUMERATED `unavailable` OUTCOME, rendered IN BAND through the SAME shared renderer.
      #
      # Routed through `render_i3` on purpose: there is exactly ONE envelope composer on this
      # surface (`Atomspace::I3Envelope.compose`) and this path must not become a second parallel
      # implementation of the no-state shape. The ONLY differences from the `not ready` render that
      # already worked are the outcome string and the reason sibling.
      #
      # ==== WHY THIS IS AN OUTCOME AND NOT A REFUSAL
      #
      # An unwired / unreachable read port is NOT a K9 refusal. K8 §5.1 scopes "refusal" exclusively
      # to a K9 ACCESS decision -- "the wiki's own signed-in session plus the Raw Data Analyst or
      # Administrator role", and "Refusal is K9's, not K8's" (`k8-draft-2.md:289-291`). A backend
      # that cannot be reached is instead the ENUMERATED OUTCOME `unavailable`: "the store could not
      # be reached or could not answer" (`:487`). So it owes the caller an envelope.
      #
      # ==== WHY IT MUST CARRY THE FULL ENVELOPE
      #
      # §5.2 is EXACT: "Every response, including every failure that is not a refusal, begins with"
      # the six-field envelope (`:300`, table `:302-310`), and §5.2's no-state rule says of the
      # triple that "epoch, position and read-at are all three PRESENT in the envelope, exactly as
      # on every other non-refusal response. The envelope's field set is uniform across all nine
      # outcomes" (`:390-392`). The previous body here --
      #   {"error":"i3_backend_unavailable","reason":"i3_read_port_unwired","_meta":{...}}
      # -- had NO top-level envelope at all and was REJECTED by the real client parser
      # (`live-bridge.mjs` `checkI3Body`) with LiveProtocolViolation on its first assertion.
      #
      # ==== THE TRIPLE IS THREE EXPLICIT NULLS, AND NO BOOTSTRAP EPOCH
      #
      # `I3ReadResult.no_state` carries NO store envelope, so `I3Envelope`'s single no-state branch
      # emits all three as exactly JSON `null` -- present, not omitted, not a mix
      # (`k8-draft-2.md:386-388`, `:396-397`, `:495-499`) -- and a known bootstrap epoch is never
      # reported here even if one were available (`:398-402`).
      #
      # `schema-version` and `limits` render as `null`: the port is unreachable, so STORE's I2-01
      # ceilings cannot be read, and their values on a no-state response ARE NOT STATED by the
      # contract. Present-and-null is the honest form -- the client checks PRESENCE only, and its
      # own doc comment confirms it "does NOT check `limits`" (`live-bridge.mjs:759-760`).
      #
      # `health` is OMITTED, never `health: null`: §5.3 requires it only "if known" on `unavailable`
      # (`:487`), and no health data exists when nothing could be reached.
      #
      # ==== WHY HTTP 200 AND NOT 503
      #
      # The contracts state NO HTTP status anywhere for this surface (the only status in the whole
      # corpus is 414 for an over-long parameter, `k8-draft-2.md:538`), so 503 was not forbidden by
      # text -- but it was UNREACHABLE IN PRACTICE. The client's `classifyHttp`
      # (`live-bridge.mjs:821`) maps any `status >= 500` to `backend-error`, and the caller throws
      # `LiveTransportFailed` (`:1052-1065`) BEFORE any parse, so `checkI3Body` (`:1101`) never ran.
      # A 503 therefore made the contract-REQUIRED `unavailable` outcome INVISIBLE to the only
      # consumer that exists. 200 is what makes the honest answer readable.
      #
      # ==== KEY ORDER AND THE DIAGNOSTIC SIBLING
      #
      # The six envelope fields come FIRST, in §5.2 row order, because `render_i3` inserts them
      # first and both Ruby hashes and JSON.generate are insertion-ordered. `reason` is passed as a
      # PAYLOAD key, so it lands strictly AFTER the envelope: it is a non-envelope operator
      # diagnostic, it is the SAME string the previous 503 carried (no new disclosure, no new
      # vocabulary), and the client provably ignores unknown keys. `_meta` is preserved by
      # `render_i3`, carrying `data_origin` -- "unavailable" whenever nothing is bound
      # (`i3_read_port.rb:93-98`).
      #
      # The class-3 Observability alert is KEPT: an unreachable backend is a genuine operator
      # signal, and this path is reached only after the authorization filters have run.
      def render_unavailable_envelope(reason)
        Atomspace::Observability.alert(signal_class: 3, payload: { signal: reason })
        render_i3(Atomspace::I3ReadResult.no_state(reason: reason),
                  payload: { "reason" => reason },
                  outcome: "unavailable")
      end

      # THE `not ready` SIBLING OF render_unavailable_envelope, for the READINESS paths.
      #
      # Identical in every structural respect -- same shared renderer, same `reason` POST-envelope
      # sibling, same preserved `_meta`, same class-3 alert, same HTTP 200 -- and differs ONLY in
      # the outcome string. The two are kept as two one-line methods over the same renderer rather
      # than one method with a flag so that each call site names the condition it is reporting:
      #   * `not ready`   -- the backend is REACHABLE but has no published, ready state
      #                      (`k8-draft-2.md:486`);
      #   * `unavailable` -- the backend "could not be reached or could not answer" (`:487`).
      # Collapsing them would misreport one as the other, which is a false statement about the
      # store even though both are no-state envelopes on the wire.
      #
      # The alert signal keeps the EXACT string the old 503 used (`i3_backend_not_ready`) so
      # existing operator alerting is unchanged, and carries the reason as its own field just as
      # before.
      def render_not_ready_envelope(reason)
        Atomspace::Observability.alert(signal_class: 3,
                                       payload: { signal: "i3_backend_not_ready", reason: reason })
        render_i3(Atomspace::I3ReadResult.no_state(reason: reason),
                  payload: { "reason" => reason },
                  outcome: "not ready")
      end

      # The backend could not produce an address/digest. Reported as the ENUMERATED `unavailable`
      # OUTCOME (in band, 200, full envelope), kept distinct from `unknown`, and NEVER satisfied by
      # a locally-computed digest.
      def render_address_unavailable(error)
        render_unavailable(error.message.presence || "backend_address_unavailable")
      end

      def render_backend_unavailable(_error)
        render_unavailable("i3_backend_unavailable")
      end

      # EVERY REMAINING AVAILABILITY PATH, through the ONE shared renderer.
      #
      # ==== WHAT THIS USED TO DO, AND WHY IT WAS THE SAME DEFECT
      #
      # It used to render
      #   {"error":"i3_backend_unavailable","reason":<reason>,"_meta":{...}}  503
      # -- no top-level envelope, and a status the real client DISCARDS BEFORE PARSING
      # (`live-bridge.mjs:821` classifies >=500 as `backend-error`; the caller throws
      # LiveTransportFailed at `:1052-1065`, so `checkI3Body` at `:1101` never runs). A previous
      # round repaired only `render_port_unwired`, which left THIS method -- the generic one every
      # other availability path funnels into (`render_address_unavailable`,
      # `render_backend_unavailable`, the atom/result contract violations in `render_card_scoped`,
      # and `render_i3`'s own Unrenderable rescue) -- still emitting the unreadable wrapper.
      #
      # It now DELEGATES to `render_unavailable_envelope`, i.e. to `render_i3` ->
      # `Atomspace::I3Envelope.compose`, so there is ONE envelope composer on this surface and the
      # outcome is the enumerated `unavailable` ("the store could not be reached or could not
      # answer", `k8-draft-2.md:487`) with the three nulls PRESENT. The operator-facing `reason`
      # string is UNCHANGED and still emitted -- as a POST-envelope sibling -- so no diagnostic is
      # lost and no new vocabulary is introduced; the class-3 Observability alert is likewise
      # unchanged (fired inside `render_unavailable_envelope`).
      #
      # ==== THE RE-ENTRY GUARD, AND WHY IT IS NOT A SILENT FALLBACK
      #
      # `render_i3` rescues `Unrenderable` by calling THIS method, so an Unrenderable raised while
      # composing the `unavailable` envelope itself would recurse. It cannot in practice -- the
      # no-state branch of `compose` takes no state source and cannot fail -- but relying on "cannot
      # happen" for a stack overflow is not a safety argument. So re-entry is detected and answered
      # with the LAST-RESORT typed error (500, ERROR_META, nothing derived from the exception),
      # which is the existing handler for "this surface is itself broken". That is a deliberate,
      # loud, non-envelope 500 -- an internal fault, not a declared backend condition -- and not a
      # degradation into a success body.
      def render_unavailable(reason)
        if @i3_rendering_unavailable
          Rails.logger.error("I3 unavailable renderer re-entered; reason=#{reason}")
          return render json: { error: "i3_internal_error", reason: "i3_unexpected_error",
                                _meta: ERROR_META },
                        status: :internal_server_error
        end

        @i3_rendering_unavailable = true
        render_unavailable_envelope(reason)
      ensure
        @i3_rendering_unavailable = false
      end

      # THE PRE-AUTHENTICATION CONFIGURATION REFUSAL'S OWN RENDERER. Deliberately NOT routed through
      # render_unavailable, and that separation is the whole fix.
      #
      # WHY ITS OWN RENDERER. This is the only refusal on this surface reachable by a caller who has
      # not authenticated at all (the guard runs inside the prepended around_action, before the auth
      # chain -- correctly so; see UnsupportedServerConfiguration). render_unavailable would hand
      # such a caller TWO things they must never get:
      #   (1) `_meta: i3_meta`, i.e. the backend's `data_origin` -- a readiness/backend signal, which
      #       the order-of-gates contract says an unauthorized caller never receives; and
      #   (2) a class-3 backend Observability alert fired ON THEIR BEHALF -- an unauthenticated
      #       caller must not be able to drive the backend alerting channel, and the misconfiguration
      #       is a SERVER fault, reported below to the server's own log instead.
      # It would also make a misconfigured server distinguishable from the normal 401 by body shape.
      #
      # So: a FROZEN CONSTANT body with NO _meta key at all (not even DENIED_META -- absent beats
      # empty, since there is nothing here any caller is entitled to know), nothing derived from the
      # request, the exception or the configuration, and NOTHING about the thread count on the wire.
      # The diagnosis -- including the actual RAILS_MAX_THREADS value -- goes to Rails.logger ONLY,
      # so the operator can still fix it. Status stays 503: the server genuinely cannot serve this
      # surface under this configuration.
      def render_unsupported_configuration(exception)
        Rails.logger.error("I3 read surface refused: #{exception.message}")
        render json: CONFIG_REFUSAL_BODY, status: :service_unavailable
      end

      # TYPED, NON-DETAILED last-resort refusal for anything unexpected on this surface.
      #
      # Replaces BaseController#handle_error (base_controller.rb:125-137) for I3 ONLY. That handler
      # renders `details: { exception: exception.class.name, exception_message: exception.message }`
      # (:134) -- deliberately, per its own T2 comment -- and on a surface whose entire design is
      # "never become an existence/permission oracle" an arbitrary exception message is exactly the
      # wrong thing to put on the wire: Card/ActiveRecord messages routinely name cards, columns,
      # ids and paths the caller may not read.
      #
      # So the response carries the error code, a FIXED reason, and NOTHING derived from the
      # exception. The class name and message still reach the operator via the SERVER-SIDE log
      # (Rails.logger) and the Observability alert -- diagnosability is preserved, disclosure is
      # not. 500, because an unexpected error is genuinely this surface's fault, not a declared
      # backend condition (503) or a missing capability (501).
      def render_unexpected_error(exception)
        Rails.logger.error("I3 read surface unexpected error: #{exception.class}: #{exception.message}")
        Rails.logger.error(Array(exception.backtrace).join("\n"))
        Atomspace::Observability.alert(signal_class: 3,
                                       payload: { signal: "i3_unexpected_error",
                                                  exception_class: exception.class.name })
        # ERROR_META, never i3_meta: this handler can run BEFORE authorization completed and can
        # run BECAUSE the port raised, so it must consult neither the backend nor the request.
        render json: { error: "i3_internal_error", reason: "i3_unexpected_error", _meta: ERROR_META },
               status: :internal_server_error
      end
    end
  end
end
