# frozen_string_literal: true

# INSERTS Atomspace::OriginalProtocolEvidence AT THE FRONT OF THE MIDDLEWARE STACK, which is
# upstream of ActionDispatch::AssumeSSL whenever AssumeSSL is present at all.
#
# mod lib is not autoloaded (same reason config/initializers/atomspace_read_client.rb:6-7 requires
# its port explicitly), so require the middleware by path.
require_relative "../../mod/mcp_api/lib/atomspace/original_protocol_evidence"

# -------------------------------------------------------------------------------------------------
# *** CORRECTION, ROUND 35 -- THE PREVIOUS insert_before(AssumeSSL) FORM COULD ABORT BOOT ***
# -------------------------------------------------------------------------------------------------
# The previous version of this file tried `insert_before(ActionDispatch::AssumeSSL, ...)` guarded by
# `if defined?(ActionDispatch::AssumeSSL)`, with a `rescue StandardError` that fell back to position
# 0. ON THE magi-dev DECK THAT CONSTRUCTION IS BROKEN, and it fails in the one direction that is
# not acceptable: it takes the whole process down at boot. Three verified facts combine:
#
#   1. `config.assume_ssl` DEFAULTS TO FALSE (railties-7.2.2.2
#      lib/rails/application/configuration.rb:48 `@assume_ssl = false`) and this deck NEVER SETS IT:
#      a grep for `assume_ssl|force_ssl` over config/, bin/ and config.ru on the deployed tree
#      (/home/ubuntu/magi-archive-port) returns ZERO matches, and no card/decko engine assigns it.
#      Therefore `ActionDispatch::AssumeSSL` is NOT in the middleware stack
#      (railties .../default_middleware_stack.rb:20-21 adds it only `if config.assume_ssl`).
#      The old header's claim that "`config.assume_ssl = true` (set in config/application.rb)" is
#      true of av-view-deck, NOT of the deployment target.
#   2. The CONSTANT is nonetheless DEFINED, because actionpack AUTOLOADS it
#      (actionpack-7.2.2.2 lib/action_dispatch.rb:67 `autoload :AssumeSSL`). So
#      `defined?(ActionDispatch::AssumeSSL)` is TRUTHY even though the middleware is absent from the
#      stack, and the old code therefore ALWAYS chose the insert_before(AssumeSSL) branch.
#   3. `config.middleware` is a Rails::Configuration::MiddlewareStackProxy: the operation is only
#      RECORDED here and REPLAYED LATER, when the application builds its middleware stack. The
#      replay reaches ActionDispatch::MiddlewareStack#insert -> #assert_index
#      (actionpack-7.2.2.2 lib/action_dispatch/middleware/stack.rb:106-108, :178-182) which does
#      `raise "No such middleware to insert before: ..."` for an unknown reference. That raise
#      happens during stack build -- NOT during this file's execution -- so the `rescue StandardError`
#      written here CANNOT see it and the position-0 fallback CANNOT run. The exception escapes and
#      ABORTS BOOT; under `Restart=always` on magi-archive.service that is a restart loop, i.e. the
#      deck goes DOWN rather than merely refusing I3.
#
# THE FIX IS TO DO UNCONDITIONALLY WHAT THE OLD FALLBACK ALREADY CALLED "strictly stronger".
# `insert_before(0, ...)` passes an INTEGER index, so `assert_index` returns it immediately without
# any stack lookup (stack.rb:179 `index.is_a?(Integer) ? index : index_of(index)`); there is no
# reference middleware to be missing and therefore nothing that can raise at replay time. Position 0
# is upstream of EVERYTHING, AssumeSSL included, so the capture this produces is never weaker than
# the old happy path -- it is the same capture or an earlier one. No behaviour of the capture itself,
# of the gate, or of any other file changes. This is the whole of the round-35 change.
#
# WHAT IS STILL TRUE AND UNCHANGED:
# * If the middleware somehow does not install, `request.env["i3.original_transport"]` is absent and
#   Atomspace::OriginalProtocolEvidence.secure?(nil) is FALSE, so the I3 surface DEFAULT-DENIES
#   (i3_read_controller.rb#assert_secure_transport!). Absence of evidence is never an allow.
# * A capture is still not an authorization: see the *** ASSUME_SSL comment in config/application.rb
#   for what this does NOT fix (a directly-reachable cleartext origin under Cloudflare Flexible).
Rails.application.config.tap do |config|
  inserted_via = nil

  begin
    # Integer index: no reference-middleware lookup, so this cannot raise at stack-build time the
    # way a class reference can. Front of stack == upstream of AssumeSSL when AssumeSSL is present,
    # and still correct when it is absent.
    config.middleware.insert_before(0, Atomspace::OriginalProtocolEvidence)
    inserted_via = "insert_before(0)"
  rescue StandardError => e
    # If even recording this operation fails, the capture is absent -- and the gate DEFAULT-DENIES on
    # an absent capture, so the surface refuses rather than serving on unverified transport. Loud,
    # not silent, and still never fatal to boot.
    inserted_via = "FAILED:#{e.class}"
    Rails.logger.error(
      "i3_transport_evidence: could NOT install original-protocol-evidence middleware " \
      "(#{e.class}: #{e.message}). The I3 read surface will refuse all requests because no " \
      "transport evidence will be captured."
    ) if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
  end

  if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
    Rails.logger.info("i3_transport_evidence: installed via #{inserted_via}")
  end
end
