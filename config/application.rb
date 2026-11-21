require File.expand_path("../boot", __FILE__)

require "decko/application"

module MagiArchive
  class Application < Decko::Application
    # Decko inherits most Ruby-on-Rails configuration options.
    # See http://guides.rubyonrails.org/configuring.html

    # EMAIL
    # Outgoing email, which is used by a lot of account processes (signup,
    # forgot password, notifications, etc) is not turned on by default.
    # To turn it on, you need to change the following to `true` and add
    # configuration specific to your site.
    #
    # Learn more about Rails email configuration:
    #  https://guides.rubyonrails.org/configuring.html#configuring-action-mailer
    #
    config.action_mailer.perform_deliveries = true
    config.action_mailer.raise_delivery_errors = true
    config.action_mailer.delivery_method = :smtp
    config.action_mailer.default_url_options = {
      host: ENV['MAILER_HOST'] || 'localhost:3000',
      protocol: ENV['MAILER_PROTOCOL'] || 'http'
    }
    config.action_mailer.smtp_settings = {
      address: ENV['SMTP_ADDRESS'] || 'localhost',
      port: ENV['SMTP_PORT'] || 587,
      domain: ENV['SMTP_DOMAIN'] || 'localhost',
      user_name: ENV['SMTP_USERNAME'] || ENV['SMTP_USER'],
      password: ENV['SMTP_PASSWORD'],
      authentication: ENV['SMTP_AUTHENTICATION'] || 'plain',
      enable_starttls_auto: true
    }

    # CACHING
    # Cards make heavy use of caching to improve performance. Caching storage
    # options include: file_store (default), memory_store, mem_cache_store...
    #
    # config.cache_store = :file_store, "tmp/cache"
    #
    # for production, we highly recommend memcache
    # here's a sample configuration for use with the "dalli" gem
    # (which you can install by adding `gem "dalli"` to your Gemfile and then
    # running `bundle install`.
    #
    # config.cache_store = :mem_cache_store, []
    #
    # Learn more about Rails caching configuration:
    #   https://guides.rubyonrails.org/caching_with_rails.html#cache-stores

    # FILES
    # Some card content (eg for Image and File cards) is stored in files
    # rather than in the database.
    #
    # Most will want to set file_storage to use either :local or :cloud.
    #
    # By default storage is set to :local, and files are stored in the "files"
    # directory in the deck root.
    #
    # config.file_storage = :local
    # config.paths["files"] = "files"
    #

    # For cloud storage use the following config options and add the
    # corresponding fog gem for your cloud service. For example for AWS add
    # `gem "fog-aws"` to your Gemfile. IMPORTANT: also see protocol and host
    # below.
    #
    # config.file_storage = :cloud
    # config.file_default_bucket = :my_bucket
    # config.file_buckets = {
    #   my_bucket: {
    #     directory: "bucket-name",
    #     subdirectory: "files",
    #     credentials: {
    #        provider: "AWS",                         # required
    #        aws_access_key_id: "key",                # required
    #        aws_secret_access_key: "secret-key",     # required
    #        use_iam_profile: true,             # optional, defaults to false
    #        region: "eu-central-1",                  # optional, defaults to "us-east-1"
    #        host: "s3.example.com",                  # optional, defaults to nil
    #        endpoint: "https://s3.example.com:8080"  # optional, defaults to nil
    #     },
    #     attributes: { "Cache-Control" => "max-age=#{365.day.to_i}" },
    #     public: true,
    #     read_only: false,                  # if true then updating a file
    #                                        # in that bucket will move it
    #                                        # to the default storage location
    #     authenticated_url_expiration: 180  # if public is set to false this
    #                                        # option is needed
    #   }
    # }
    #
    # Learn more about file storage options:
    #   http://decko.org/file_storage_options)


    # ORIGIN AND RELATIVE_ROOT
    # The following option is used when generating absolute links and
    # are necessary when using cloud file storage, especially when using
    # commands (like `decko update`) in a non-web context.
    #
    # Without it your generated CSS (which is stored on the cloud) will not
    # be able to find permanent resources (which are stored with the deck).
    # This usually shows up as broken icons.
    #
    config.deck_origin = ENV.fetch("DECK_ORIGIN", "https://wiki.magi-agi.org")
    #
    # If your deck is not at the url's root but in a subdirectory, such as
    # mysite.com/mydeck, then you must configure the relative_url_root:
    #
    # config.relative_url_root = "/mydeck"

    # ===========================================================================================
    # TLS / TRANSPORT POLICY -- SECURITY-HARDENING SUBSCOPE (separately approvable, see below)
    # ===========================================================================================
    #
    # These three settings change TLS and redirect behaviour for the WHOLE deck, not just the I3
    # surface, so each is DEFAULT-ON BUT ENV-REVERSIBLE and each rollback is a single env flip plus
    # a restart -- no code change. Companion pieces:
    #   * mod/mcp_api/lib/atomspace/original_protocol_evidence.rb  (pre-rewrite evidence capture)
    #   * config/initializers/i3_transport_evidence.rb             (inserts it before AssumeSSL)
    #   * config/initializers/session_store.rb                     (SESSION_COOKIE_SECURE)
    #
    # GUARDS KEY OFF EXPLICIT ENV VARS, NEVER Rails.env. The server here is Thin 2.0.1 and
    # config/puma.rb:10 is `environment ENV["RACK_ENV"] || "development"`, so RACK_ENV/Rails.env is
    # NOT a reliable indicator of whether this process is the internet-facing one. Keying TLS
    # policy off it would mean a production deploy that forgot RACK_ENV silently runs with TLS
    # enforcement off. Explicit vars cannot drift that way.

    # ASSUME_SSL. Tells Rails the request arrived over TLS even though the origin hop is cleartext
    # -- required for correct absolute URLs, redirects and `Secure` cookies behind a TLS-
    # terminating proxy.
    #
    # READ THIS BEFORE TREATING IT AS A SECURITY CONTROL: `assume_ssl` trusts the forwarded
    # protocol **UNCONDITIONALLY**. It does not consult a trusted-proxy list, and there is no
    # option to make it. So under Cloudflare Flexible SSL, an attacker who can reach the origin
    # DIRECTLY in cleartext is ALSO treated as HTTPS by Rails. Nothing in this file or in the I3
    # middleware changes that for the deck at large; the I3 surface defends itself by reading
    # pre-rewrite evidence plus a trusted-proxy allowlist, but the rest of the deck does not.
    #
    # THE REAL FIX IS INFRASTRUCTURE, NOT CODE, and is explicitly NOT closed here:
    #   (1) Cloudflare SSL/TLS mode -> Full (Strict) so the Cloudflare->origin hop is TLS, and
    #   (2) an origin firewall restricted to Cloudflare's published IP ranges, and
    #   (3) any directly-reachable origin port closed.
    # OWNER ACTION. Also NEEDS-CONFIRMATION: the actual proxy topology and TLS termination point
    # for dev-wiki.magi-agi.org is not established from this repo and is not assumed here.
    config.assume_ssl = ENV["ASSUME_SSL"].to_s.strip != "0"

    # FORCE_SSL. Redirects http->https and marks cookies secure.
    #
    # HIGHEST-BLAST-RADIUS ITEM IN THIS SUBSCOPE: if the origin is genuinely reachable only over
    # cleartext and `assume_ssl` is NOT in effect, force_ssl produces an infinite redirect loop /
    # total lockout for every user. ROLLBACK: FORCE_SSL=0 and restart.
    config.force_ssl = ENV["FORCE_SSL"].to_s.strip != "0"

    # HSTS for one year, with subdomains and preload-eligible, plus a redirect exclusion for the
    # health endpoints.
    #
    # WHY THE HEALTH EXCLUSION: an uptime/load-balancer probe hitting the cleartext health path
    # would otherwise receive a 301 and may score that as a failure. `redirect: { exclude: }`
    # suppresses only the REDIRECT for those paths -- it does not disable HSTS and it does not
    # weaken the I3 gate, which is enforced independently in the controller.
    #
    # HSTS IS NOT TRIVIALLY REVERSIBLE: once a browser has cached max-age it will refuse plain HTTP
    # to this host for a year regardless of server config. To actually back it out you must serve
    # `max-age=0` for long enough for clients to re-fetch it; FORCE_SSL=0 alone does NOT undo
    # already-cached HSTS in browsers that saw it.
    config.ssl_options = {
      hsts: {
        expires: 1.year,
        subdomains: true,
        preload: true
      },
      redirect: {
        exclude: ->(request) { request.path.start_with?("/api/mcp/health") }
      }
    }

    # ENV VARS INTRODUCED BY THIS SUBSCOPE (all default-ON; only the literal "0" disables):
    #   ASSUME_SSL=0                   -> stop trusting the forwarded protocol
    #   FORCE_SSL=0                    -> stop redirecting http->https (lockout escape hatch)
    #   SESSION_COOKIE_SECURE=0        -> restore the previous `secure: false` session cookie
    #   I3_REQUIRE_SECURE_TRANSPORT=0  -> disable the I3 transport gate only
    #   I3_TRUSTED_PROXY_CIDRS=<list>  -> comma/space separated CIDRs whose X-Forwarded-Proto is
    #                                     honoured. UNSET = TRUST NOBODY = cleartext REFUSED on
    #                                     the I3 surface. This one is fail-closed when unset, so
    #                                     it must be SET for the I3 surface to serve behind a
    #                                     proxy.

    # MISCELLANEOUS
    # You can use the following to disallow creating, updating, and deleting
    # cards:
    #
    # config.read_only = true
  end
end
