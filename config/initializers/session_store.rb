# frozen_string_literal: true

# SESSION COOKIE POLICY. Part of the separately-approvable security-hardening subscope -- see
# config/application.rb (ASSUME_SSL / FORCE_SSL) and
# mod/mcp_api/lib/atomspace/original_protocol_evidence.rb.
#
# SECURE NOW DEFAULTS **ON**, which is a behaviour change. The previous value was a hard
# `secure: false` with the comment "Changed to false because Cloudflare Flexible SSL sends HTTP to
# server". That reasoning is about the ORIGIN hop, but `Secure` is a instruction to the BROWSER and
# the browser's connection is to Cloudflare over HTTPS -- so under Cloudflare Flexible the cookie
# is still sent on every real request. Leaving it off meant the session cookie would also be sent
# over any plaintext URL a user could be induced to load, which is exactly what `Secure` exists to
# prevent.
#
# ROLLBACK: SESSION_COOKIE_SECURE=0 restores the old `secure: false` behaviour with no code change.
# Default-ON by construction: only the literal string "0" disables it, so an unset variable leaves
# the control ON.
#
# BLAST RADIUS IF THE TOPOLOGY ASSUMPTION IS WRONG: if any user-facing path genuinely terminates
# at the browser over plain HTTP (not just origin-side cleartext behind Cloudflare), browsers will
# DROP the session cookie and users cannot stay signed in. Symptom is "login appears to succeed
# then immediately logs out". The flip above is the fix.
session_cookie_secure = ENV["SESSION_COOKIE_SECURE"].to_s.strip != "0"

# SAME_SITE IS DELIBERATELY :lax AND MUST NOT BE TIGHTENED TO :strict.
#
# Decko emails TOP-LEVEL navigation links for account confirmation and password reset. With
# `:strict` the session cookie is withheld on a cross-site top-level GET, so following one of those
# emailed links lands the user in a signed-out state and the confirmation/reset flow BREAKS. That
# is a functional regression, not a hardening win.
#
# And the risk :strict would buy down is not present here: the I3 read surface is GET-only
# (config/routes.rb -- lookup/health/open/neighbours are all `get`), and Rails' own CSRF token
# protects the state-changing Decko forms. :lax already withholds the cookie on cross-site
# POST/PUT/DELETE, which is where CSRF actually lives.
session_same_site = :lax

Rails.application.config.session_store :cookie_store,
  key: '_magi_archive_session',
  same_site: session_same_site,
  secure: session_cookie_secure,
  httponly: true,
  expire_after: 2.hours

# Framework-level SameSite default, kept in agreement with the cookie above for the same reason
# (emailed top-level links must keep working).
Rails.application.config.action_dispatch.cookies_same_site_protection = session_same_site
