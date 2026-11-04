# AtomSpace Mirror: Magi Archive Runbook

Operating the Decko/Postgres to AtomSpace mirror on a Magi deck. Canonical designs: card 17120 (system plan), card 17161 (implementation plan), card 17184 (read API).

The mirror is one-way. Postgres stays authoritative, and the mirror writes only `mirror_*` tables and the in-memory Space. Local tests have run; a clean test run is not proof for a host, so collect the evidence each step names.

**Dev only as written.** Prod needs the extra preconditions under "Host trust boundary" first.

## Topology

| Process | Runs as | Purpose |
|---|---|---|
| `atomspace-mirror-sidecar` | `atomspace` | In-memory Space on `127.0.0.1:9407` plus the privileged socket `/run/atomspace-mirror/sidecar.sock` |
| `atomspace-mirror-drain` | `ubuntu` | Singleton forward drain |
| `atomspace-mirror-drift` | `ubuntu` | Report-only stream monitors |
| Web (`magi-archive`) | `ubuntu` | Save hook and the read API |

Templates are in `deploy/systemd/`. Never `systemctl enable` the sidecar or drain: a reboot must not start an empty Space or resume a drain into it. Any sidecar exit is an incident, and recovery is the coordinated rebuild.

**Two env files.**
- `/home/ubuntu/magi-archive/.env.production`: DB credentials, `RAILS_ENV`, the activation gate, the grant lists, and the `SIDECAR_*` values. Web, drain and drift read it.
- `/etc/atomspace-mirror.env`: tunables only. The sidecar, drain and drift read it. No secrets.

`SIDECAR_RUN_DIR`, `SIDECAR_RUN_DIR_MODE=0750` and `SIDECAR_SOCKET_MODE=660` must be identical in both.

## Operator traps

These were each found by running the port.

- **Use `decko runner`, not `rails runner`.** On this deck `bundle exec rails runner '...'` prints the `rails new` help and **exits 0**, so it silently checks nothing.
- **Copying from a Windows clone:** `git archive` follows `core.autocrlf` and writes CRLF, which breaks blob-fidelity checks. Use `git -c core.autocrlf=false archive`.
- **Test databases:** `rake card:seed` removes the three mirror rows from `schema_migrations`. Re-insert them after seeding a test DB. This does not arise on a refreshed dev DB, which is not seeded.
- **`MCP_USERNAME` may need to be an email.** Login by plain username failed on a seeded DB because `UserAuthenticator` looks up the compound `+*account+*email` card with `find_by_name`; login by email worked. Not yet confirmed on real data. Try the email if a connector gets `Invalid credentials`.
- **No-DB and DB-backed specs cannot share one `rspec` run:** the no-DB specs stub `Card`.

## Gates

- `ATOMSPACE_MIRRORING_ENABLED` must be exactly `true` to activate. Any other value is dormant.
- Pin the DB: on every DB command print env, host and database first. Dev also runs `RAILS_ENV=production`, so the host is what tells them apart.
- Migrate with `rake db:migrate:up VERSION=<v>`, never `decko update`, which ignores the mod's migration path. Versions, in order: `20260614000001`, `20260623000001`, `20260624000001`.
- Take an RDS snapshot before migrating. Local `pg_dump` may be older than the server.
- Stop processes with `systemctl` or the pidfile, never a broad `pkill`.
- No branch switching in a dirty deploy tree. Back it up first.

## Refresh precondition

A DB restore invalidates all mirror state. Order: dormant code, **refresh**, ACL audit, mirror migrations, bootstrap. Never bootstrap the pre-refresh dataset.

Before any refresh:

```bash
RAILS_ENV=production bundle exec rake mirror_refresh:assert_precondition
```

It refuses while the gate is set or any `mirror_*` table exists. Also stop the sidecar.

## STRICT dataset filter

The policy is locked: Administrator documentation by ancestry, UNION cards whose effective READ set is solely Administrator and/or Nemquae. Cards shared with anyone else are kept. Work on a **staged copy**, never in place over the live dev DB.

```bash
OUT=manifest.json RAILS_ENV=production bundle exec rake mirror_refresh:strict_manifest   # read-only
CONFIRM_DB=<live db name> RAILS_ENV=production bundle exec rake mirror_refresh:strict_apply   # DESTRUCTIVE
```

Re-derive the manifest from a fresh copy every time; earlier figures are snapshots. It carries ids and counts only. Apply removes the cards with their history, references, virtuals and now-empty acts. Children of an excluded card go too, because they cannot survive their parent; read `dependents` in the manifest before applying. A rule that cannot be resolved blocks apply.

The filter does **not** cover:

- attachment blobs outside the database (`attachment_card_ids` lists them);
- search artifacts;
- credential records, which are sanitized separately and never copied into a repo or log;
- restoring dev-only Administrator docs and accounts, which goes through the application layer with fresh ids, because their old ids collide with retained prod cards.

This policy grants no AtomSpace scope to anyone.

## ACL-cache audit

Reads re-evaluate `card.ok?(:read)` against the cached `read_rule_id` and `read_rule_class`. A restore can leave those wrong, and Decko's own repair only fixes NULLs.

```bash
RAILS_ENV=production bundle exec rake mirror_refresh:acl_audit           # read-only; ids and counts
RAILS_ENV=production REPAIR=1 bundle exec rake mirror_refresh:acl_audit  # repairs mismatches, re-audits
```

Each row resolves from a cold, private cache, so the verdict depends on the rows and not on what the process read first. A full scan takes longer for it: budget minutes, not seconds. The rake task runs with the shared cache off, so its report says `shared_cache_checked: false`. That is right for a staged copy. Before setting any grant on a running deck, run `bundle exec rake atomspace_mirror:assert_grantable`: it needs a clean audit and a checked shared cache, and it refuses otherwise. If it finds a stale copy, run `MirrorAclAudit.repair!` from a runner with the shared cache on, because a repair from the isolated task cannot reach the store.

It exits non-zero unless clean, and repair creates no card actions. The audit also compares the rule on the shared store's copy when there is a store to read, because every read goes through `Card.fetch`, and repair expires the card. Columns alone can look clean while the old rule is still enforced. **Grant no AtomSpace scope until it is clean.** While grants are active, **re-run it after any `+*read` rule save**: the `permission_propagation` mod's `*right` branch does not repair descendants. If `*right`-governed cards are wrong, hard stop: no grant beyond the owner's admin principal until repaired.

## Host trust boundary

Inventory before activation (G-UID), names only:

```bash
for u in $(systemctl list-units --type=service --state=running --no-legend | awk '{print $1}'); do
  systemctl show -p Id -p User -p Group "$u"
done
ps -eo user,comm | sort -u
docker ps --format '{{.Names}}' | xargs -r docker inspect --format '{{.Name}} {{.HostConfig.NetworkMode}} {{.Config.User}}'
```

DEV controls:
- Sidecar as `atomspace:atomspace`; `ubuntu` in group `atomspace`; run dir `0750`; socket `0660`.
- An iptables `owner` rule on `127.0.0.1:9407` admitting only the `ubuntu`, `atomspace` and root UIDs. On a host with ufw, insert it above the ufw jumps (`iptables -I`), because ufw accepts all loopback traffic first. It does not survive a reboot. Host-network containers running as root pass it. The MCP host allowlist does not protect this port.

**Honest limit: this is not a boundary against other processes running as `ubuntu`.** They inherit the group and already hold the DB credentials. If they tamper with the Space, forged atoms may be served until a sweep finds them. Postgres is unaffected. **Activation is prohibited where untrusted code shares the deck's UID.**

Prod preconditions: the deck on a dedicated UID, Unix-only sidecar transport, and an instance handshake.

The sidecar repo has no license file. That is a metadata note, not a legal judgement.

## Grants and audience

Holders of `mcp:atomspace:read` are trusted with the Space-global view (G-AUDIENCE). The `limit` is pre-auth best-effort, so a holder can infer that a hidden value exists, and aggregates cover the whole Space.

- Grant only to principals entitled to that view, by explicit `user:<name>` entries in `ATOMSPACE_READ_GRANTS` or `ATOMSPACE_ADMIN_GRANTS`.
- No role, including Administrator and Raw Data Analyst, confers a scope. API keys get nothing, and non-user tokens are refused.
- **Before admitting anyone not entitled to the whole Space:** post-auth truncation becomes a precondition, and that deviation from card 17184 needs owner approval.
- After changing a list, restart web. Issued tokens keep their scopes until expiry (`MCP_TOKEN_TTL`, default 3600 s).

## Activation

Set the gate before bootstrap, so the hook captures saves made during the sweep.

1. **Preflight.** Print env, host and db; confirm 0 of 3 mirror migrations; gate unset; `Cardio.config.delaying` false (`decko runner 'puts Cardio.config.delaying'`); no sidecar pidfile or socket. The app also refuses to boot if the gate is set while delaying is on.
2. **RDS snapshot.** Confirm it completed.
3. **Migrate**, in order. Verify 4 tables and exactly one `mirror_state` row with `draining_enabled=false`.
4. **Start the sidecar.** Verify `curl -s http://127.0.0.1:9407/space_stats` shows `atom_count: 0`, and `stat -c '%U:%G %a' /run/atomspace-mirror /run/atomspace-mirror/sidecar.sock` shows `atomspace:atomspace 750` and `660`.
5. **Set the gate** in `.env.production`, then restart web and every process that can save a card. Check each one's environment by **name only**; never print values.
6. **Bootstrap** with the drain stopped: `rake atomspace_mirror:bootstrap`. Verify the run is `completed`, and `cards_swept` equals `Card.where(trash: [true, false]).count` in a write-quiet window.
7. **Memory guard.** Measure sidecar RSS and atom count, then set `MemoryMax` to 2-3x the measured RSS. The source deck measured about 358 MB at about 17K atoms; re-measure here and abort if far above budget.
8. **Start the drain**, then wait for lag 0.
9. **Start drift monitors.** Schedule `atomspace_mirror:drift_sweep` off-hours.
10. **Verify.** Run one full sweep, then grant scopes, then run real atom queries and ACL negatives through the deck API and MCP. Counts alone are not acceptance.

## Reading drift results

Expect `stable=true` with `pg_only = space_only = mismatch = 0`.

**A `mismatch` right after a rule change is not necessarily corruption.** Decko rewrites `*recent settings` when a new setting rule appears, without an outbox row, so the sweep correctly reports it. Rename side effects on referers behave the same way. Check the sample ids in the run's `report_path`, then repair:

```bash
RAILS_ENV=production bundle exec rake 'atomspace_mirror:reconcile[<run_id>]'
```

Then let the drain finish and sweep again. `space_only` is different: never reconcile it outside a maintenance window, because it quarantines.

## Quarantine: maintenance only

Quarantine removes a card's `DeckoCard` atom outright. Readiness fails closed when the DeckoCard count falls below the last bootstrap's `cards_swept`, and that gate covers every read action, including further quarantine calls.

So delete requires read + `mcp:atomspace:admin`, plus `ATOMSPACE_QUARANTINE_DELETE_ENABLED=true`. Set the flag only inside a declared window, and end every window with a coordinated rebuild:

1. Declare the window and set the flag.
2. Quarantine. Save the returned removed-atom list: it is content-bearing, admin-only, and the only full record. Run reports keep the first 50.
3. Expect `503 sidecar_below_expected`. This is the correct state, not a fault.
4. Run the coordinated rebuild, then unset the flag and restart web.

**With headroom, the trap does not fire.** If net-new cards since the last bootstrap outnumber those removed, reads stay at 200, but the Space is still wrong until the rebuild. Always finish with the rebuild.

Never lower the threshold to clear `sidecar_below_expected`. Re-establish the baseline. The same applies after a hard purge from Postgres.

## Coordinated rebuild

1. `systemctl stop atomspace-mirror-drain` (it may already have stopped).
2. `systemctl restart atomspace-mirror-sidecar`, then confirm `atom_count == 0`.
3. `rake atomspace_mirror:bootstrap`. It is not idempotent; on failure, restart the sidecar and repeat.
4. Check the memory guard, then run one stable `drift_sweep`.
5. `systemctl start atomspace-mirror-drain`. Reads recover by themselves.

Afterwards run `rake atomspace_mirror:requeue_failed` if rows failed during the incident.

**Provenance is not restart-durable.** Bootstrap restores cards and references only, so `get_card_provenance` shows only post-rebuild events. `card_actions` and `mirror_outbox` remain the durable audit.

## Disabling and re-enabling

**Unsetting the gate does not pause the drain, and records no edits made while disabled. Readiness cannot see that gap.** After re-enabling, stale atoms are served with `200`.

To disable, do both: unset the gate and set `draining_enabled=false`, then restart the writers. Outbox rows stay inert.

To re-enable, keep agents off until one of these is done:

- **(a)** a coordinated rebuild; or
- **(b)** `coverage_gap = 0` after `rake atomspace_mirror:remediate_hook_lag` (repeat until zero) **and** a stable sweep with zero drift.

## MCP connectors

The AtomSpace tools live on their own surfaces, never on the public tool list: `POST /atomspace/mcp` on the MCP service, and `bin/mcp-server-atomspace` over stdio.

| Situation | HTTP | Stdio |
|---|---|---|
| No valid session | `401` with OAuth discovery | Not applicable |
| Deck reachable, no read scope | `403` | Zero tools |
| Deck unreachable | `503` with `Retry-After` | `tools/list` is a JSON-RPC error; `tools/call` is a tool error saying to retry |
| `GET` on the route | `405`; the route is POST-only | Not applicable |

- **Grant changes take effect at the next token.** A token keeps the scopes it was minted with. The gem refreshes it about 5 minutes before expiry, so a removed grant takes up to `MCP_TOKEN_TTL` minus 5 minutes to reach a running session, and the deck enforces the same token until then. A stdio process picks up the change without a restart.
- **`subscribe` is not implemented.** It returns a structured 501. Poll with `wait_for_event_id` instead.

The sidecar's Unix socket calls have deadlines: 10 seconds by default for a read (`SIDECAR_READ_TIMEOUT_SECONDS`; the dev host at 27,000 atoms needs 60) and 30 seconds for a quarantine. The drain's read timeout is `ATOMSPACE_DRAIN_READ_TIMEOUT` in `/etc/atomspace-mirror.env` (the client default is 5 seconds; the dev host needs 120), because one apply is two full scans of the Space. A sidecar that stops answering gives `503` on reads and a recorded failure on quarantine. Raise the read deadline only if R8 measures legitimate reads near it.

The sidecar refuses to start if its run directory still has any "other" permission bits after `chmod`, for example a directory root pre-created as `0755`. Fix the directory's owner or mode; do not widen `SIDECAR_RUN_DIR_MODE`.

## Read-your-writes limits

`wait_for_event_id` reveals a status only for a card the caller can read. An unreadable card and a nonexistent event look the same, including timing. So **waiting on a deleted card's event returns `503 staleness_timeout` for everyone**, because trash is not fetchable; this is expected. MCP write APIs expose `act_id`, not `card_actions.id`, so clients may not be able to construct these event ids yet.

## Rollback

| What | How | Effect |
|---|---|---|
| Code | Redeploy the preserved prior SHAs | Mirror never writes Decko tables |
| Activation | Disable as above | Hook no-ops, reads 503 |
| Sidecar, drain, drift | Stop drift, then drain, then sidecar; remove the 9407 owner rule | Space discarded |
| Schema | Three-version rollback below | **Loses outbox rows and run reports.** Take a fresh snapshot first if they matter |
| Grants | Remove entries, restart web | New tokens lose scopes at once; issued ones at expiry. Immediate cut-off means rotating the signing key, a credential action |
| Data already served | Cannot be recalled | Prevention only |

```sql
DROP TABLE IF EXISTS mirror_reconcile_runs, mirror_bootstrap_runs, mirror_outbox, mirror_state CASCADE;
DELETE FROM schema_migrations WHERE version IN ('20260614000001', '20260623000001', '20260624000001');
```

A mirror migration already applied at preflight means halt and inventory, not rollback.

## Observability

Report-only. Stream monitors log JSON to `Rails.logger`; **no alert sink is wired**, so nobody is paged when reads start returning 503.

```bash
RAILS_ENV=production bundle exec decko runner 'puts MirrorOutbox.group(:status).count.to_json'
RAILS_ENV=production bundle exec decko runner 'puts MirrorState.first.attributes.slice("bootstrap_a_start","last_drained_action_id","draining_enabled").to_json'
```

Never print env files or tokens. Sidecar and DB watermarks are not expected to match; the sidecar exceeding the DB is the alarm.
