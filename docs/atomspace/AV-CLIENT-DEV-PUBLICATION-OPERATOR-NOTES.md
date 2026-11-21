# AV-CLIENT DEV publication — operator notes

Documentation successor for the DEV publication of the AtomSpace Visualizer client entry
point. It changes no runtime, policy, configuration, contract or deployment, and it records
only what saved evidence supports.

Companion documents: `docs/atomspace/I3-VIEW-PROTOTYPE-CLOSEOUT.md` (the VIEW surface this
client reads through) and `mod/mcp_api/public/av-client/README-HOSTING.md` (the hosting
mechanics, written at an earlier checkpoint). Where this note and an earlier note differ,
this note governs only for the facts it cites.

## Two asset trees, and why both are published

The client assets exist twice in this deck:

| role | tree |
|---|---|
| mod source | `mod/mcp_api/public/av-client/…` |
| served copy | `public/mod/mcp_api/av-client/…` |

Only the **served** copy is inside the HTTP document root. On the DEV deployment the request
path `/mod/mcp_api/av-client/src/demo/live.html` is proxied to the application server, and the
application serves it statically out of `Rails.root/public` — so the mod-source-shaped path
`/mod/mcp_api/public/av-client/…` is **not routable** and returns 404 at the origin. A front-end
`root` directive declared for a different tree is not consulted for this URI, because no static
`location` matches it.

On the DEV deployment the two copies are **separate regular files**, not a symlink pair and not
hardlinks. That is not what the framework's own task produces, so **there is no automatic sync**:

- `card:mod:symlink` (aliased into `card:setup` and `card:update`, and re-exported as
  `decko:mod:symlink`) is the only code path in the card/decko gem set that writes under
  `public/`. It removes **the whole of** `public/mod` and then symlinks each mod's `public`
  directory back in.
- Nothing schedules it: no timer, no cron entry, no boot hook, no `ExecStartPre`, no card event.
  The current layout was produced by a manual copy.

Both copies are therefore updated deliberately on every publication, for two reasons:

1. HTTP serves only the `public/` copy, so that copy must hold the intended build.
2. If an operator later runs the `card:mod:symlink` family, `public/mod` is wiped and the mod
   source becomes the served bytes immediately and permanently. Keeping the mod source equal to
   the published build makes that step safe rather than a silent rollback.

Neither statement claims that anything overwrites the served copy automatically today. The
negative inventory behind the second point was bounded to the deployment's own gems, units,
timers, cron and application config as read at the time; it is not a proof that no future script
or operator action can do so. The practical rule: **treat the `card:mod:symlink` family as
destructive to `public/mod`**, and expect a mod-source-only edit to be invisible over HTTP until
that task or a manual copy runs.

## Publication procedure, as actually executed

The publication was a bounded manual operation, not a pipeline. Its shape, in order:

1. **Preflight.** Rehash the local candidate; read the pinned manifests rather than assuming
   them; confirm both deployment targets still hold the previous build, are still not symlinks,
   and have no symlink on any path component — re-checked immediately before the write so there
   is no gap between check and use. Fetch the pre-publication body over HTTPS **twice**, once
   against the origin directly and once through the public edge, and require both to agree, which
   is what proves the edge is serving live origin bytes rather than a cached copy.
2. **Backups.** A fresh, uniquely timestamped backup directory **outside both asset trees**,
   owner-only (`0700`) with owner-only backup files (`0600`), created with copy-no-clobber plus an
   explicit abort if it already exists, holding: a backup of each of the two previous copies, a
   record of the real pre-write file metadata of both originals, and a frozen copy of the staged
   new build, hash-verified on the deployment before any target is touched. No backup overwrites
   anything and no earlier receipt is modified.
3. **Write.** In-place content replacement, which **preserves inode, owner and mode** — no
   delete-and-recreate, no directory sync, no rsync, no unrelated mod publish, no dependency
   upload. Post-write both copies were confirmed byte-equal to the staged build at their original
   inodes with ownership and mode unchanged.
4. **Readback.** Re-fetch over HTTPS from both the origin and the public edge, compare the bodies
   byte-for-byte against the staged source, and re-verify the unchanged dependency modules in both
   trees. No cache purge and no configuration change were part of this.
5. **Rollback, if ever needed:** restore the **served** copy first and verify over HTTP, **then**
   restore the mod source and verify. The order matters because only the served copy affects what
   users receive.

**No rollback was performed.** One acceptance attempt was blocked by an **expired viewer session**
upstream of the client: the client's mandatory pre-flight lookup answered HTTP 401 and the client
refused the read, drew nothing, and substituted no recording — the specified behaviour, and not a
fault in the published build. Rolling back would have reproduced the identical refusal while
discarding a correctly published, byte-verified artifact, so the build was left published and the
acceptance was completed later against a valid session.

## What the published build is, and what the delta covered

- The publication changed **exactly one file**, the client entry point. Its eight dependency
  modules were unchanged from the previous release and were re-verified in both trees after the
  write; each digest appears exactly twice, once per tree.
- One further file in the asset directory, the hosting README, was **deliberately excluded** from
  the publication. No wildcard copy was used.
- The entry point's published digest and byte size, the predecessor digest, and the module
  digests are all pinned in the client lane's committed delta manifest and restated in the client
  lane's closeout note (`design/056-client-prototype-closeout.md` on `ws/client-e1` in
  `Magi-AGI/atomspace-visualizer`). The local source still hashes to the published value — no
  drift between the committed source and what is served.

**A pinning caveat worth knowing before reading that manifest.** The delta manifest's own status
fields still say the build is a local, unpublished candidate with no deployment performed. That
was true when the manifest was generated and is **false now**. The manifest was deliberately
**not edited** — it is a frozen historical candidate record, and the publication receipts and the
closeout notes are its successors. Take the publication state from the successors, not from the
manifest's status fields.

## Acceptance evidence, and the distinction that is easy to lose

Two things that look like one thing:

- **Selecting a node, or paging a bucket, is not traversal.** Neither pushes navigation history,
  so neither causes the viewer's in-page `Back` control or a non-current breadcrumb to render. An
  intermediate acceptance pass reported success while the traversal path was still unexercised for
  exactly this reason. That is an early status, not a defect — nothing was found to be broken.
- The closing pass therefore exercised **three distinct actions as real clicks**: expanding a card
  that was genuinely different from the view's root (which is what first materialises the trail),
  then the viewer's **own in-page `Back`** (not the browser's), then a **non-current breadcrumb**
  to return forward. The read timestamp advanced on every leg, the trail proved bidirectional and
  self-consistent, and the retained graph stayed stable — a return is a **fresh re-read of focus**,
  never a snapshot restore, and retention is additive-merge.

Reported counts rose across successive stages of one accumulating graph (two nodes, then seven,
then nine) as further buckets were ingested. Those are stages, not contradictions, and the
accumulated retained total is reported separately from what the latest action itself contributed —
quoting one figure without saying which it is reintroduces a confusion the build was changed to
remove.

Two evidentiary limits, stated plainly:

- The publication identity was **carried forward** into the final acceptance record rather than
  re-measured during that pass. The byte-level proof is the publication readback, which does not
  depend on the session.
- Error evidence is an explicit error-vocabulary scan of the page's accessibility surface, not a
  browser console log, and that walk is bounded — absence from it is not proof of absence on
  screen. Substring hits on `401`/`403` inside hexadecimal scene digests are false positives.

A separate, dedicated check established the **rendered direction of one `left-part` edge** from a
saved frame: the arrowhead sits at the far end and is **mostly occluded by that node's label box**,
so the finding rests on off-stroke pixel mass at that end matched against a visible control
arrowhead, plus the absence of any such mass at the other end. The rule is positional, not
role-based; an earlier prediction from source reasoning had the direction reversed and is
corrected. This is **not** the same question as reciprocal-link distinctness, which is proven at
the atom level from distinct keys and digests rather than from arrows read off a canvas.

## Limits of this record

- Documentation only. No runtime, configuration, contract, schema, test, fixture, grant or
  deployment change, and no test was run for this note: every statement is drawn from saved
  evidence from the publication and acceptance passes.
- The acceptance was a **bounded DEV pass**, not an end-to-end production approval. Production has
  no deployment of this work.
- The GPU path was demonstrated on one machine configuration that the evidence does not identify,
  so nothing here generalises to another browser or a software rasteriser.
- Operational detail — deployment host identity, absolute filesystem paths, backup locations,
  process identifiers, grant and role settings — is **deliberately excluded** and is held
  privately. It is not needed to read this note.
- Single-author, unreviewed. No checkpoint, release, freeze or approval status is created here.

## Carried forward, not actioned here

- A **manual access revocation for the read surface remains outstanding, and nothing expires on
  its own** — there is no auto-expiry mechanism, so it only ends when somebody performs it. No
  grant was created, changed or revoked by the publication or acceptance work.
- A **post-mortem on a missed 2026-11-16 delivery commitment is still outstanding**; it was
  deferred and has not been written. No cause is asserted here.
- Any further runtime evidence requires a **live signed-in session** on the DEV wiki; with an
  expired session the client refuses by design and produces no telemetry. That is a prerequisite,
  not a defect.
- A general process rule worth keeping: when driving a real browser, require a **fresh
  active-origin check and a fresh UI-automation element handle before every single input**, and
  fail closed rather than falling back to coordinate clicks — a stale handle must refuse rather
  than land somewhere else.
