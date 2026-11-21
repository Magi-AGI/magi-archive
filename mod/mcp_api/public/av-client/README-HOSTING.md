# Hosting the av-client from this mod — required layout, URLs, and the operator step

**Nothing here is deployed.** This directory is the SOURCE tree. It becomes a served URL only
after an operator runs the rake task named at the bottom of this file. No file in this repo
creates the link at boot.

## 1. How a local mod's `public/` becomes a URL (the real mechanism)

Decko documents the contract in `decko/card/lib/cardio/mod.rb:30`:

> `**public** - accessible via the web at DECK_URL_ROOT/mod/MOD_NAME/`

That mapping is **not** implemented by a controller, a route, or a `Mod#public_path` method. It is
implemented by a **filesystem symlink** created by a **rake task**:

- `decko/card/mod/core/lib/tasks/card/mod.rake:8-17` — `card:mod:symlink`:
  ```ruby
  task :symlink do
    FileUtils.rm_rf public_mod_dir          # :10  -- wipes public/mod ENTIRELY
    FileUtils.mkdir_p public_mod_dir        # :11
    Cardio::Mod.dirs.each_subpath "public" do |mod, target|
      link = public_mod_dir mod             # :13
      FileUtils.rm_rf link                  # :14
      FileUtils.ln_sf target, link          # :15  -- symlink, per mod that HAS a public/ dir
    end
  end
  ```
- `decko/card/mod/core/lib/tasks/card/mod.rake:40-42` — the link location is
  `File.join(Rails.public_path, "mod", mod_name)` → `av-view-deck/public/mod/mcp_api`.
- `decko/card/lib/cardio/mod/dirs.rb:132-134` + `:95-97` — `each_subpath("public")` yields
  `mod.subpath("public")` for **every** mod in load order, and `Cardio::Mod#subpath`
  (`mod.rb:63-69`) returns the path **only if `File.exist?`**. So a mod with no `public/` dir is
  skipped silently — which is why this directory must exist in the source tree before the task is
  run.
- Local (deck-level) mods are included: `dirs.rb` adds gem mods via `add_gem_mod` (`:138-149`) *and*
  deck mod dirs, so `av-view-deck/mod/mcp_api` is enumerated like any gem mod. The existing links
  in this deck confirm the shape — `git ls-files -s public/mod/` reports mode **120000** (symlink)
  for `ace_editor`, `bootstrap`, `style`, `tinymce_editor`, each pointing at a gem's `public` dir
  (e.g. `public/mod/style` → `…/card-mod-style-0.19.1/public`). They are **symlinks**, not pointer
  text files.
- When the link is missing, Decko does not 404 silently with a generic message; it has a dedicated
  hint: `decko/decko/lib/card_controller/rest.rb:24-26` renders
  `"Decko installation error: missing public directory symlinks"` and logs
  `">>> Try `rake card:mod:symlink`"`.

**Static delivery** is `ActionDispatch::Static` over `Rails.public_path`, enabled by
`decko/card/config/environments/production.rb:21` (`config.serve_static_files = defined?(Rails::Server)`)
and `…/test.rb:23`. `config.relative_url_root` is **commented out** in
`av-view-deck/config/application.rb:113`, so URLs are **not** prefixed — `/mod/mcp_api/...` is
correct as written.

### Who creates it — and what you must do

| Question | Answer |
|---|---|
| Rake task? | **Yes — `rake card:mod:symlink`** (aliased into `card:setup` and `card:update`, `card.rake:6,16`; also run in `decko/docker/repos/decko-bundled.dockerfile:4` and `decko-k8s.dockerfile:37`) |
| `Mod#public_path`? | **No such method.** `Cardio::Mod` has `subpath`, not `public_path`. The carrierwave `public_path` (`mod/carrierwave/lib/carrier_wave/file_card_uploader/path.rb:20`) is for **file-card attachments**, unrelated to mod assets. |
| Symlink at boot? | **No.** No initializer, engine hook, or `to_prepare` creates it. Rake only. |
| Pointer text file (like `public/mod/style`)? | **No.** Those are real symlinks (git mode 120000). |

> **OPERATOR STEP REQUIRED (not performed here):** `bundle exec rake card:mod:symlink` in
> `av-view-deck`, which creates `public/mod/mcp_api` → `mod/mcp_api/public`.
> ⚠️ **It `rm -rf`s all of `public/mod` first** (`mod.rake:10`) and recreates every mod link, so
> run it only when every mod is resolvable. On Windows, `FileUtils.ln_sf` needs symlink privilege
> (Developer Mode or elevation); if symlinks are unavailable, the operator must copy
> `mod/mcp_api/public` → `public/mod/mcp_api` instead.

## 2. REQUIRED layout — two levels, not flat

`live.html` lives at `src/demo/live.html` and imports `'../drawn-graph.mjs'`. A **flat**
`av-client/live.html` would request `/mod/mcp_api/av-client/drawn-graph.mjs` and **404**. The
`src/` + `src/demo/` relationship is therefore **load-bearing** and must be preserved:

```
mod/mcp_api/public/av-client/
  src/
    drawn-graph.mjs              <- imported as ../drawn-graph.mjs from src/demo/*
    presentation-registry.mjs
    demo/
      live.html                  <- the launch page
      demo-mode.mjs
      live-bridge.mjs
      fixture-bridge.mjs
```

That 6-file set is the complete import closure, and it is the **REQUIRED** layout. All six are
now **staged in this deck** (measured below), so the layout above describes both the requirement
and the current on-disk state.

#### Present vs. absent, as measured in this deck checkout

Measured contents of `av-view-deck/mod/mcp_api/public/av-client/` right now — the directory holds
two files **and a populated `src/` subtree. `src/` EXISTS and all six client modules are
present:**

| Path (relative to `mod/mcp_api/public/av-client/`) | State | Bytes | sha256 |
|---|---|---|---|
| `README-HOSTING.md` | ✅ present (this file) | — | — |
| `README-HOSTING.md.bak-r29blockers-pre` | ✅ present (backup) | — | — |
| `src/` | ✅ **present — the directory exists** | — | — |
| `src/drawn-graph.mjs` | ✅ **present** | 47590 | `f660022e7ccad84b738319569dcc1d508127c11353e556440425d7dafa102eda` |
| `src/presentation-registry.mjs` | ✅ **present** | 32244 | `543c8dc1afa879ecbcb5eccbd47e812afb0e9a823c47f51e0193c4244deceb5b` |
| `src/demo/live.html` | ✅ **present** | 16500 | `96405fa9b7fdf2a78f02b78dc10027a237b9bfee651f496b5ecda5b8a5fd5775` |
| `src/demo/demo-mode.mjs` | ✅ **present** | 13731 | `d75a0c1f062913f8f6e992f1ab162839318e529193de0acd9c25bb33c0441481` |
| `src/demo/live-bridge.mjs` | ✅ **present** | 67780 | `c59569c11c0e84a71af0a3eb2ee2dc7b8152b0b1e96891edc82f109df6bbb615` |
| `src/demo/fixture-bridge.mjs` | ✅ **present** | 17821 | `fca80f9f4b70a9a440e20262fb5a157cf46221c62571054c184041a2e75d034c` |

These six files are **byte-identical** to the copies carried in the av-view cpd026 package payload
at `payload/mod/mcp_api/public/av-client/src/…` (same sha256 in the package's `manifest.json`).
They are **untracked** in git.

> **SUPERSEDED:** earlier revisions of this section stated "There is NO `src/` directory" and
> marked all six modules ABSENT. That was true when written and is **no longer true** — the files
> have since been staged. The sizes and hashes in the table above are the current measurement.

**CONSEQUENCE — the documented launch URL still cannot resolve today.** Staging the six files was
necessary but **not sufficient**. `<DECKO_ROOT>/public/mod/mcp_api` **does not exist**:
`public/mod/` currently contains only `ace_editor`, `bootstrap`, `style` and `tinymce_editor`.
Because `ActionDispatch::Static` serves from `public/`, nothing under `mod/mcp_api/public/` is
reachable over HTTP until that mapping from §1 is created. So
`/mod/mcp_api/av-client/src/demo/live.html` **cannot resolve** — the remaining gap is the
`public/mod/mcp_api` symlink/copy, not the client files.

> **Note:** no HTTP request was made from this host. The statement above is derived from the
> measured presence of the six files, the measured **absence** of `public/mod/mcp_api`, and the
> `ActionDispatch::Static` mechanism in §1 — **not** from an observed HTTP response. No status
> code has been verified for any URL in this document.

### Resulting URLs

```
/mod/mcp_api/av-client/src/demo/live.html
/mod/mcp_api/av-client/src/demo/demo-mode.mjs
/mod/mcp_api/av-client/src/demo/live-bridge.mjs
/mod/mcp_api/av-client/src/demo/fixture-bridge.mjs
/mod/mcp_api/av-client/src/drawn-graph.mjs
/mod/mcp_api/av-client/src/presentation-registry.mjs
```

**Exact launch URL** (same-origin, empty `backend=` so the client uses this origin):

```
/mod/mcp_api/av-client/src/demo/live.html?mode=live&backend=&card=<NAME>
```

### ⚠️ The docs' URL is WRONG

`cpd023:203` and `cpd025:405` state the launch URL as:

```
/mod/mcp_api/av-client/live.html        <-- WRONG, 404s on ../drawn-graph.mjs
```

That assumes a flat copy, which **breaks the import closure**. Both documents must be corrected to
the `src/demo/live.html` path above. This is a documentation defect, not a client defect.

## 3. `.mjs` MIME type — not registered in the locked Rack; the fix initializer IS now present

`ActionDispatch::Static` resolves `Content-Type` through `Rack::Mime::MIME_TYPES`.

- `Gemfile.lock:466` locks **`rack (2.2.22)`**.
- In that version, `rack-2.2.22/lib/rack/mime.rb:286` registers `".js" => "application/javascript"`
  and **has no `".mjs"` entry at all** (grep for `mjs` in that file returns zero hits — verified on
  this host).
- `.mjs` therefore falls back to `application/octet-stream`, and a browser **refuses an ES module
  with a non-JavaScript MIME type** (strict MIME checking for `<script type="module">` /
  `import`). **Every `.mjs` import above would fail to execute.**
- Rack 3.x *does* include `.mjs` → `text/javascript` (confirmed against rack 3.2.4 on this host),
  so this breaks specifically because the deck is pinned to Rack 2.
- No MIME registration exists anywhere in this deck: grep for `Mime::Type.register` / `MIME_TYPES`
  across `config/` returns zero hits.

**One-line fix** (a NEW standalone initializer, e.g. `config/initializers/mjs_mime_type.rb`):

```ruby
Rack::Mime::MIME_TYPES[".mjs"] ||= "text/javascript"
```

`Mime::Type.register "text/javascript", :mjs` is **not** sufficient on its own — that registers an
Action Dispatch *response format*, whereas static file delivery reads `Rack::Mime::MIME_TYPES`.

**APPLIED — the initializer is present in this deck checkout.**
`av-view-deck/config/initializers/mjs_mime_type.rb` **exists now** and is **untracked** by git
(`git status` reports it as `??`; `git ls-files` returns nothing for it), so it is present in the
working tree but not yet committed. Measured on this host:

| Property | Measured value |
|---|---|
| Path | `av-view-deck/config/initializers/mjs_mime_type.rb` |
| Size | **1719 bytes** |
| `sha256` | `7cde8fd4cce1d041f85e5d2e5e440a5eaaac5b9e124daf467cda80ffbca1df11` |
| Git state | **untracked** (`??`) |

That digest is **byte-identical** to the cpd026 package payload copy at
`av-view/deploy/cpd026-same-origin-i3-package/payload/config/initializers/mjs_mime_type.rb`
(same sha256, same 1719 bytes — both measured here).

⚠️ Earlier revisions of this section said the initializer was **"NOT APPLIED … deliberately left to
the staging worker."** That statement is **stale and wrong** as of this measurement: the file is in
the tree. It is still **uncommitted**, and no HTTP/Rails/browser verification of the served
`Content-Type` has been performed on this host — only the on-disk file's presence, size and digest
were measured.

## 4. The I3 read binding — three operator requirements this repo CANNOT satisfy itself

The live page needs a wired `I3ReadPort`, which `config/initializers/i3_read_binding.rb` installs
when an operator sets `I3_READ_BINDING=live` — the literal string `live`, **not** `=1` and not any
other truthy spelling — plus **six** companion `I3_*` variables. That is **SEVEN required entries
in total**, and the binding fails closed (unwired port, clean 503) if any one of them is missing or
malformed:

| # | Variable | What it must contain |
|---|----------|----------------------|
| 1 | `I3_READ_BINDING` | the literal string `live`. Any other value (including `1`, `true`, `yes`) does **not** activate the binding. |
| 2 | `I3_I2_INTERPRETER` | absolute path to the python interpreter that runs the sidecar script. |
| 3 | `I3_I2_SCRIPT` | absolute path to the STORE sidecar entry script `i2_stdio_reader_service.py`. |
| 4 | `I3_STORE_SIDECAR_PATH` | absolute path to the store sidecar data path handed to the child. |
| 5 | `I3_I2_SCRIPT_SHA256` | **MANDATORY content pin** — `46b0f687c02b8e5df078a3bea4b7322149019c79939782ca607528d09cd52f88`. Must be 64 **lowercase** hex characters; anything else (wrong length, uppercase, non-hex, absent) is **strictly rejected** and the binding refuses to install. The script bytes are re-hashed and compared before launch. |
| 6 | `I3_I2_DEADLINE_MS` | the per-read deadline in milliseconds. **Authoritative value for this package: `2000`.** This supersedes the stale `30000` found in the phase8b / `PHASE8-CONSOLIDATED` documents — do not carry that value forward. |
| 7 | `I3_I2_CONFIG` | an **inline JSON document** (the configuration itself, passed by value). It is **NOT a filename** — do not point it at a path. |

Those seven **bind the port**. Three further variables are evaluated **per request, after the
binding succeeds**, and a bound port still answers **503 on every I3 request** if the first is
missing:

| Variable | Status | What it must contain |
|---|---|---|
| `I3_TRUSTED_PROXY_CIDRS` | **MANDATORY — not optional hardening** | `127.0.0.1/32`. Unset ⇒ **every I3 request returns 503**, even with all seven binding variables correct. **Do NOT list Cloudflare edge CIDRs**: the edge talks to **nginx**, which proxies to Rails over loopback — Rails never sees an edge address. |
| `I3_READ_GRANTS` | **REQUIRED for the token / API path** | `user:Nemquae` — the grant the token path derives the `mcp:i3:read` scope from. |
| `I3_REQUIRE_SECURE_TRANSPORT` | **DELIBERATELY NOT SET** | **Default-ON**; only the literal string `"0"` disables it. Leaving it unset is the intended secure configuration — do not export it. |

Two further invariants of the launch, both enforced by the initializer:

* **argv is exactly `[interpreter, script]`.** There is **no `--serve` flag**. Passing `--serve`
  makes the sidecar exit `2` with `usage error: unsupported arguments`.
* **The child environment is exactly three non-secret keys** — `AV_STORE_SIDECAR_PATH`,
  `AV_I2_STDIO_CONFIG` and `PYTHONUNBUFFERED` — spawned with `unsetenv_others: true`, so the
  parent's environment (and every `I3_*` secret-adjacent value in it) is **not** inherited by the
  child.

Three things about that are
**operator work**, and none of them is applied by any file in this repo.

### 4.1 Puma preload + workers — the hook that must be added by hand

`config/puma.rb` as committed is a **preforking, preloading** configuration:

```ruby
workers Integer(ENV["WEB_CONCURRENCY"] || 0)   # :1
preload_app!                                   # :6
```

With `WEB_CONCURRENCY` > 0, `preload_app!` means the app — and therefore
`config.after_initialize` — boots **once in the Puma master**. Every worker is then `fork`ed from
it and **inherits the already-bound port and the master's pipe file descriptors without ever
calling the installer**. Two or more workers writing to one child's stdin interleave
newline-delimited frames and corrupt the I2 protocol. A per-process guard cannot fix this on its
own, because under preloading nothing in the worker runs the installer at all.

**What the initializer now does about it (already applied):** the `after_initialize` path
**refuses to bind** whenever `WEB_CONCURRENCY` names a forking deployment — an unset or explicit
`0` binds normally, and anything else (including an unparseable value) is treated as preforking.
The result is an unwired port and a clean **503**, never a shared pipe. It also resets the port if
it ever detects a binding whose installing pid is not the current pid.

**What an operator must do — pick ONE of these TWO (there is no valid third option):**

**(a) Add the per-worker hook to `config/puma.rb`.** ⚠️ **NOT EDITED BY THIS CHANGE.**
`config/puma.rb` is a tracked deployment file; this work was not authorized to modify it. Add
exactly:

```ruby
on_worker_boot do
  Atomspace::I3ReadBindingInstaller.install_for_worker!
end
```

`install_for_worker!` is the explicit post-fork entry point: it disowns any inherited claim first
(resetting the port rather than serving over the parent's pipes), then starts **that worker's own**
child. One child per worker, no sharing. Without this line, a `WEB_CONCURRENCY>0` deployment stays
at 503 by design.

**(b) Or run single-process:** `WEB_CONCURRENCY=0` (or leave it unset). The `after_initialize`
path then binds normally because no fork happens.

**(c) — SUPERSEDED / INVALID. DO NOT FOLLOW.** An earlier revision of this section offered a third
option, *"drop `preload_app!`* so each worker boots the app itself and `after_initialize` runs once
per worker". **It does not work.** The initializer's refusal keys off **`WEB_CONCURRENCY`** — the
guard (`prefork_configured?`) reads only that env var, never `preload_app!`. With
`WEB_CONCURRENCY` > 0, removing `preload_app!` still leaves the `after_initialize` path refusing to
bind, so the port stays **unwired** and every I3 route keeps answering **503**. Only **(a)** and
**(b)** are valid.

### 4.2 `I3_I2_SCRIPT` must name STORE's service, not the deck's model server

There are **two** stdio readers in this workspace and only one can project a card.

| Script | Use for `I3_I2_SCRIPT`? | Why |
|---|---|---|
| `av-store-sidecar/tools/i2_stdio_reader_service.py` | ✅ **YES** | STORE's launcher (`:48` hands over to `i2_stdio_service.main()`). Its service module `atomspace_mirror_sidecar/i2_stdio_service.py` is the only one that implements the projection: `store-projection` is in `CONFIG_KEYS` (`:116`), the attested partial card is loaded at `:274-275`, validated at `:301-315`, and the coverage disclosure is exposed through the STORE-local `store-projection` operation (`:113-114`, `:519`). It is also the script `Spawn`'s contract was written against (`:5-9`). |
| `av-view-deck/tools/i2_stdio_reader_server.py` | ❌ **NO** | VIEW's **model server** — STORE calls it exactly that (`i2_stdio_service.py:17`, `:31`). It has **no `store-projection` support**: its config goes straight to `I2Config.from_mapping` (`:112`), and the only way it ever acquires state is the operator-only `--seed-from-golden-vectors` flag (`:289-339`, explicitly "NOT DEV data"), which `Spawn#start!` **cannot pass** because it runs exactly `[interpreter, script]` with no argv (`i2_stdio_transport.rb:314-316`). Pointed at by `I3_I2_SCRIPT` it serves an **empty store — "not ready" forever**. |

So `I3_I2_SCRIPT` should be
`<I3_STORE_SIDECAR_PATH>/tools/i2_stdio_reader_service.py`. The initializer's header was corrected
to say this; it previously named "the deck's `tools/i2_stdio_reader_server.py`", which was wrong.

**The failure mode of naming the wrong script — stated consistently.** The initializer does **no
discovery**, and naming the deck's own `tools/i2_stdio_reader_server.py` is **not guaranteed to
produce a spawn failure, a contract violation, or a crash.** The honest description is:
`Spawn#start!` can launch that script and the binding can be installed, but because the script has
**no `store-projection` support** and its only state source is the operator-only
`--seed-from-golden-vectors` flag that `Spawn#start!` **cannot pass** (it execs exactly
`[interpreter, script]` with no argv, `i2_stdio_transport.rb:314-316`), the result is a
**permanently NOT-READY reader serving an EMPTY store** — i.e. **unsuitable for projection**, with
reads answering **503**. Any wording elsewhere that promises a guaranteed spawn/contract *failure*
for a wrong `I3_I2_SCRIPT` is superseded by this paragraph: treat a wrong script as *unsuitable for
projection*, **not** as a crash that will announce itself.

> **Still blocked upstream:** even the correct script serves no real card content today. The
> projection needs a `store-projection` block pointing at an attested card payload, and no such
> attested/captured JSON exists on disk yet.

### 4.3 Owned-child shutdown — the "restart reaps it" claim, corrected

`deploy/cpd026-same-origin-i3-package/ROLLBACK.md:221-223` (in the **av-view** repo) says the
reader child is reaped by restarting Rails normally, citing `I2StdioTransport::Spawn`'s stop path.
`Spawn#stop!` does exist and is bounded with escalation (`i2_stdio_transport.rb:358-401`, returning
`:confirmed` / `:unconfirmed`) — but **nothing used to call it at process exit**, so the claim was
not true of anything in this deck.

**Now fixed in the initializer, with a stated limit.** A successful bind registers an `at_exit`
hook, scoped to the installing pid (at_exit handlers are inherited by forks, so the hook is a
no-op in any process that does not own the child). It calls `shutdown_owned_child!`, which resets
the port and calls `Spawn#stop!` exactly once.

**The corrected operator expectation:**

- A **graceful** stop/restart (Puma's own shutdown, `SIGTERM`, `SIGINT`, a normal exit) **does**
  now run the hook and stop the owned child.
- **`at_exit` does NOT run on `SIGKILL`, a hard crash, or a `taskkill /F`.** The runbook's
  "check for a survivor" step therefore **remains necessary**, and the hunt-and-kill commands in
  ROLLBACK Step 5 are still correct — just no longer the *only* reaping mechanism.
- A stop whose verdict is **`:unconfirmed`** does **not** drop the reference: the Spawn is retained
  in `I3ReadBindingInstaller.unreaped_spawns` so a later attempt can still find a process that may
  still be alive. An unconfirmed stop is reported in the log and is never reported as a completed
  shutdown.
- The same cleanup now runs on two paths that previously leaked: turning the master switch off
  after a successful install (the port is reset and the child stopped, rather than keeping a stale
  live binding), and any post-spawn failure (a client constructor that raises, or a declined
  binding, now stops the started child instead of orphaning it).

> **Nothing above is deployed by this repo.** The initializer only wires a port when an operator
> sets the env vars, and the `config/puma.rb` line in §4.1 must be added by an operator.

---

## PROVENANCE — cpd038 documentation correction (2026-11-16)

Closes **cpd034 CRITICAL BLOCKER 4** / **agy BLOCKERS 1–2** for this hosting README. Documentation
only — **no code, no spec and no deployment; nothing here was executed or observed.**

* The **SEVEN**-entry activation table (incl. the mandatory `I3_I2_SCRIPT_SHA256` pin) was already
  correct as of cpd036 and is left intact.
* **`I3_I2_DEADLINE_MS` is now pinned to `2000`** — superseding the stale `30000` in the phase8b /
  `PHASE8-CONSOLIDATED` documents, and replacing the earlier "no documented value" instruction.
* **NEW:** the **request-path gates** are documented for the first time —
  `I3_TRUSTED_PROXY_CIDRS=127.0.0.1/32` is **MANDATORY** (unset ⇒ `503` on every I3 request even with
  a correctly bound port; **no Cloudflare edge CIDRs**, the edge talks to nginx, never to Rails),
  `I3_READ_GRANTS=user:Nemquae`, and `I3_REQUIRE_SECURE_TRANSPORT` is **deliberately unset**
  (default-ON; only the literal `"0"` disables it).
