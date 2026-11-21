# frozen_string_literal: true

# Register `.mjs` as a JavaScript MIME type for STATIC file delivery.
#
# WHY THIS FILE EXISTS
# The same-origin AtomSpace I3 browser client is plain ES modules served as
# static files out of a mod's public/ directory (see
# mod/mcp_api/public/av-client/README-HOSTING.md). Static files are delivered by
# ActionDispatch::Static, which resolves Content-Type through
# Rack::Mime::MIME_TYPES -- NOT through ActionDispatch's format registry.
#
# This deck locks rack 2.2.22 (Gemfile.lock). rack-2.2.22/lib/rack/mime.rb
# registers ".js" => "application/javascript" and has NO ".mjs" entry at all.
# An unregistered extension falls back to application/octet-stream, and browsers
# apply a STRICT MIME check to `<script type="module">` and to every `import`
# specifier: application/octet-stream is refused outright. The result is a blank
# page with no server-side error -- the modules are fetched with HTTP 200 and
# then discarded by the browser.
#
# Rack 3 ships ".mjs" => "text/javascript", so this shim becomes redundant (and
# stays harmless) whenever this deck moves to Rack 3. `||=` means we never
# override a value the stack already provides.
#
# WHY NOT `Mime::Type.register`
# `Mime::Type.register "text/javascript", :mjs` registers an ActionDispatch
# response FORMAT for controller-rendered responses. It does not affect static
# file delivery, so it would NOT fix this. The Rack table is the one that is
# consulted for files under Rails.public_path.
#
# SCOPE: content-type only. This file grants nothing, authenticates nothing,
# reads no ENV, opens no socket and spawns no process.

Rack::Mime::MIME_TYPES[".mjs"] ||= "text/javascript" if defined?(Rack::Mime::MIME_TYPES)
