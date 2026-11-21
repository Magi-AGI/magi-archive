# frozen_string_literal: true

# =================================================================================================
# RUNTIME ACTIVATION OF THE I3 READ BINDING ON **THIN 2.0.1**
# =================================================================================================
#
# THE BLOCKER THIS CLOSES. `config/initializers/i3_read_binding.rb` builds the binding and exposes
# `Atomspace::I3ReadBindingInstaller.install_for_worker!` (i3_read_binding.rb:280-282), but the only
# caller it ever documented was a **Puma** `on_worker_boot` block placed in `config/puma.rb`.
# This deck is served by **thin 2.0.1** (Gemfile:17 `gem "thin"`, Gemfile.lock:616 `thin (2.0.1)`).
# Thin never reads `config/puma.rb` and has no `on_worker_boot`, so that hook CANNOT RUN and
# `install_for_worker!` had NO runtime caller outside spec/ -- leaving the port unwired and every I3
# route answering 503. This file is that caller.
#
# -------------------------------------------------------------------------------------------------
# *** CORRECTION, ROUND 34 (Codex blocker 2) -- THE PREVIOUS JUSTIFICATION HERE WAS WRONG ***
# -------------------------------------------------------------------------------------------------
# This header used to assert: "IT CALLS `install_for_worker!`, NEVER `install!`", on the grounds
# that `install!`'s `prefork_configured?` refusal reads only `WEB_CONCURRENCY`, is Puma-shaped, and
# would be a false refusal under thin. Codex rejected that reasoning, correctly:
#
#   "Activation calls the worker-only entry point without establishing a Thin serving-process
#    context. Consequently, it defeats the prefork-master refusal implemented at
#    config/initializers/i3_read_binding.rb:327 and can create the inherited-pipe condition that
#    refusal prevents."
#
# `install_for_worker!` is the entry point that is ALLOWED to bind under a preforking
# WEB_CONCURRENCY, because it is meant to run IN a worker, AFTER the fork
# (i3_read_binding.rb:272-282). Calling it from an `after_initialize` block proves nothing about
# being post-fork: this file cannot know what server loaded it. Taking the bypass unconditionally
# therefore disarmed `refuse_prefork_master!` (i3_read_binding.rb:526-540) for every topology,
# including the preforking one it was written to protect -- where a binding installed in the MASTER
# is inherited by every worker and puts several writers on one child's stdin.
#
# THE TRADE IS NOT SYMMETRIC, which is why the fix goes this way: a stray WEB_CONCURRENCY causing a
# false refusal costs a 503 that an operator can see and fix; binding in a preforking master
# silently corrupts the line protocol. So the decision is now EVIDENCE-BASED and fails CLOSED:
#
#   * `Atomspace::I3ThinLifecycle.activate!` takes the `install_for_worker!` bypass ONLY when
#     `thin_serving_context?` returns true -- i.e. only on an affirmative observation that this
#     process is really serving (`EventMachine.reactor_running?` literally true, or a live
#     `Thin::Server` whose `running?` is literally true). Absence of evidence, a nil/false answer
#     or ANY raised error all count as NOT PROVEN.
#   * NOT PROVEN routes to `install!` instead, so `refuse_prefork_master!` applies again and a
#     preforking deployment fails closed to 503 rather than binding in a master.
#   * Because a Rails `after_initialize` block runs when the Rack app is built -- which is BEFORE
#     thin starts its reactor (controller.rb:72 vs controller.rb:87; INFERENCE from thin's
#     published source layout, NOT read on this host: thin is not installed here) -- a strict gate
#     would always fail at this point in boot. So activation DEFERS itself once per process into
#     `EventMachine.next_tick`, re-entering `activate!` inside the reactor where the evidence can
#     actually exist. That path returns `:deferred_to_reactor` and binds NOTHING yet.
#   * With no EventMachine at all there is nothing to wait for, so the immediate `install!` path is
#     taken -- again the fail-closed direction, never the bypass.
#
# Which entry point was used is recorded in `I3ThinLifecycle.activation_attempts` and surfaced in
# `I3ThinLifecycle.state`, so a reviewer can confirm the bypass was only ever taken on evidence.
#
# PROVENANCE HONESTY. Thin, EventMachine, Rails, decko and card are NOT INSTALLED on the host where
# this change was written, so no claim here about real thin/EM runtime behaviour has been executed
# or observed; the thin lifecycle statements are inferences from published sources. What IS proven
# by execution is this file's and the lifecycle module's control flow, against doubles, in
# `spec/mcp_api/i3_round34_thin_lifecycle_proof.rb`.
#
# -------------------------------------------------------------------------------------------------
# ORDERING. The filename sorts AFTER `i3_read_binding.rb` ("i3_r" < "i3_t"), and Rails loads
# `config/initializers/*.rb` in sorted order, so `Atomspace::I3ReadBindingInstaller` is already
# defined when this file is read. The `after_initialize` block below runs later still (after
# eager-load), so ordering is not actually load-order sensitive -- but the require is defensive
# anyway, because mod lib is NOT autoloaded by Decko (same constraint as
# i3_read_binding.rb:17-19 / atomspace_read_client.rb:3-6).
#
# RELATIONSHIP TO THE OTHER INITIALIZER. This file does NOT redefine, reopen or monkey-patch
# `I3ReadBindingInstaller`, and it does not edit `i3_read_binding.rb`. If BOTH files' hooks run,
# the result is still at most one child: `install!` and `install_for_worker!` share the same
# `@installed_pid` guard (i3_read_binding.rb:321 `return true if @installed_pid == Process.pid`),
# and `I3ThinLifecycle.activate!` additionally short-circuits on its own pid guard.
#
# FAIL-CLOSED AND SILENT WHEN OFF. `I3_READ_BINDING` must be exactly "live" or this file does
# NOTHING and logs nothing (the switch is re-checked inside `activate!`). Every failure is swallowed
# into a logged refusal; nothing here can raise across boot.
# =================================================================================================

begin
  require ::File.expand_path("../../mod/mcp_api/lib/atomspace/i3_thin_lifecycle", __dir__)
rescue ::StandardError, ::ScriptError
  # A missing lifecycle file must not take boot down with it; the guard below then simply no-ops
  # and the port stays unwired (=> 503), which is the documented fail-closed end state.
  nil
end

if defined?(::Rails) && ::Rails.respond_to?(:application) &&
   ::Rails.application.respond_to?(:config) && defined?(::Atomspace::I3ThinLifecycle)

  ::Rails.application.config.after_initialize do
    # Arm the shutdown hooks FIRST and UNCONDITIONALLY-when-live, so that even a refused or
    # DEFERRED activation leaves this process able to stop and report a child that started but
    # could not be bound -- and, since round 34, to re-stop retained unreaped spawns as well
    # (both hooks route through `shutdown!`, which always sweeps).
    #
    # The EM hook is the deterministic one: thin's real shutdown is understood to reach
    # `EventMachine.stop` (backends/base.rb:96) from BOTH `Server#stop` (server.rb:171) and
    # `Server#stop!` (server.rb:187) -- i.e. from INT and from TERM/QUIT via the queued-signal
    # timer (server.rb:235-244, 247-259) -- and `EventMachine.stop` drains the hooks registered by
    # `add_shutdown_hook` (eventmachine.rb:199-200, 291-293). `at_exit` backs it up for the
    # non-signal exits and for the case where thin did not start the reactor itself
    # (`@started_reactor == false`, base.rb:96 / server.rb:188-194). Both statements are
    # INFERENCES from published sources; neither gem is installed on the host where this was
    # written, so neither was observed here.
    ::Atomspace::I3ThinLifecycle.register_shutdown_hooks!

    # May return :activated, :refused, :deferred_to_reactor, :already_active, :off or
    # :unavailable. Under thin the expected answer AT THIS POINT is :deferred_to_reactor -- the
    # real bind happens in the reactor callback, where a serving process can be proven.
    ::Atomspace::I3ThinLifecycle.activate!(reason: "rails_after_initialize_thin")
  rescue ::StandardError, ::ScriptError
    nil # never crash a serving process into a restart loop over this.
  end
end
