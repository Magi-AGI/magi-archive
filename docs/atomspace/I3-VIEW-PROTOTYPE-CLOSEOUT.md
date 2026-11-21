# I3 VIEW prototype closeout

Documentation successor to the implementation published at
`dd76bff7aae1da81f99e98e1b5d1ac4fe390ff79` on `ws/view-d-deck`.
This note changes no runtime, policy, configuration, contract, or deployment.
Historical code comments and hosting notes describe intermediate checkpoints;
this document records the supported completion claims and their limits.

## Architecture and ownership

The read path is **CLIENT → authenticated Decko I3 → private STORE I2**.
I2 is not the browser API and carries no user identity or role. PostgreSQL
remains the wiki's authoritative database; the prototype reads a bounded
export-backed projection, not a replacement database or continuous feed.

- **Controller:** `mod/mcp_api/app/controllers/api/mcp/i3_read_controller.rb`
  owns session/token entry checks, caller-scoped Decko authorization, request
  validation, name resolution, and response rendering. Lookup does not grant
  access by resolving a name. Missing and unreadable names collapse to the
  same refusal-safe lookup outcome.
- **Port and binding:** `i3_read_port.rb`, `local_i3_read_binding.rb`, and
  `i3_read_result.rb` preserve the validated envelope alongside the reading.
  They must not reduce a stateful result to a bare array or invent success.
- **Process client and transport:** `i2_reader_process_client.rb`,
  `i2_stdio_transport.rb`, and `i2_envelope.rb` validate private STDIO responses.
  Neighbours' subject identity is enriched from an actual I2-02 response only
  when its epoch and position agree with the reading. A request address or
  display label is not substitute response evidence.
- **Projection and serialization:** `i3_envelope.rb` owns
  `I3Envelope.compose` and structured graph projection. CLIENT owns graph
  ingestion, presentation, layout, interaction and browser state.
- **Operations:** DEV-RUNTIME owns deployment, input selection, restarts,
  backup and rollback. VIEW's packages and historical approvals are not
  instructions to deploy an arbitrary later working tree.

## Actual CLIENT-facing shape

Lookup, open and neighbours return a **flat top-level I3 body**, not a nested
STDIO frame and not the former `{results, _meta}`-only wrapper. The six
unconditional envelope keys are `outcome`, `epoch`, `position`, `read-at`,
`schema-version`, and `limits`. Structured `participant`, `buckets` and neighbour
`entries` carry the graph; legacy `results` is not its replacement. A parser
accepting the envelope alone does not prove graph ingestion or drawing.

STORE-issued keys, digests, atom text, position arrays and sampled state
metadata are preserved, not reconstructed from labels. Schema and limits are
sourced from I2-01. A read timestamp is not source freshness: the export has no
as-of instant. Absent upstream health/runtime information must not be invented;
the health capability remains explicitly limited, and a null polling-interval
value is not an implemented polling service.

`unknown`, `reload`, `not ready` and `unavailable` are meaningful outcomes, not
aliases for an empty graph. Only the no-state outcomes permit the state triple
to be present and all-null. In-band availability responses are distinct from
pre-auth/configuration refusals and internal HTTP faults; HTTP 200 alone proves
neither payload readiness nor rendering.

## Identity, authorization, absence and continuation

A participant is not necessarily a Card. Authorized unresolved participants
retain their wire key/digest, class, null trash value and structured
`label.head` / `label.parts`; code must not require `label.name`. The exception
for an unresolved target comes from STORE declarations and its owning link,
not a global grant to all non-Card expressions. Declaration evidence must match
the projected reading's **epoch and position**; uncertainty denies the exception.
The consumer's structured-label fix belongs to CLIENT, not wire coercion in Ruby.

Authorization applies before structured emission, including identities embedded
in link keys and continuation coordinates. A genuinely empty STORE list is not
equivalent to a nonempty list whose entries were all denied. The latter uses the
existing absence/unavailable behavior instead of claiming a complete empty page.
Unauthorized continuations are withheld or refused; readable continuations may
remain. Existing omission/count information is not a new ACL-marker vocabulary,
and complete omission accounting remains an integration/contract limitation.

Inbound `after` crosses controller → port → binding → process client → STORE.
Entry and link cursors include the audited `neighbour` and `after-link` forms.
The current caller is re-authorized for cursor identities and embedded link
participants; shape, requested subject and epoch are checked. STORE handles
cursor state/retention semantics. This is **no privilege escalation**, not a
proof of issuance, a signature, a replay ban, or principal-exclusive ownership.
Another independently authorized caller can legitimately reuse a cursor.

VIEW 046/047 is important here: the demand for an issuance/principal registry
was withdrawn by the same Codex reviewer as having **no normative basis**.
P2 declaration-state binding and P3 `reload` preservation were closed; P1 was
withdrawn, not implemented. Closure was **Codex-only**, not dual-review approval.
Earlier comments saying a cursor is "proven STORE-issued" or inert for every
other principal overstate the supported property. No policy change is made by
this clarification.

## What the evidence establishes

These are saved results, **not tests rerun for this documentation pass**:

| Evidence class | Supported result | Not established by it |
|---|---|---|
| Python adapter/conformance | Final archive records 836 passed, 1 transport-ceiling skip | Rails routing, sessions, database or browser behavior |
| Actual controller under isolated harness, real STORE child and real CLIENT exports | Envelope/structured-graph failures were reproduced and repaired; later 046 records 154 assertions and six non-throwing ingestions | Execution of Rails filters, real Decko ACLs or full label painting |
| Candidate I2 capture projected through the real Ruby methods | 049 records 134 assertions and eight ingestion cases, with separately coherent epochs | A live HTTP service or signed-in browser session |
| Code inspection and review | Documents authorization, state binding and lifecycle mechanisms; focused findings have explicit dispositions | Independent execution, comprehensive security assurance or dual approval |
| Signed-in Firefox DEV receipts | Later deployed snapshot: real lookup/reads, visible WebGPU graph, inspection/expansion, actual in-page Back and non-current breadcrumb actions; final scene reports nine nodes and 17 connections | Exhaustive authorization matrix, full-wiki scale, latency/freshness targets or all user/browser cases |

The separate saved direction verdict checks arrow placement, rather than deriving
it from navigation order. Browser traversal and arrow direction are different
claims. Return re-opens focus through a new read while retaining accumulated
scene contents; it is not historical snapshot restoration. Earlier replay pages
labelled `live-http-i3` were still replay and are not the later signed-in proof.
The completion card and CLIENT/DEV-RUNTIME receipts own that later runtime result;
private captures and their operational details are deliberately not published here.

**The Decko RSpec suites were not run:** the required dependencies and database
were absent. The publication pass's **40 Ruby, two Python and five JavaScript
syntax checks are not behavioral tests**. No CI verification is available to
substitute for those missing suites. A workflow file in ancestor history is not
proof that this branch or its authorization paths passed CI. The current
integration commit is not certified merely because a particular deployed snapshot
worked in Firefox.

## Consolidation prerequisites, not merge instructions

At the recorded publication boundary, `main` was
`605351f9250021f30d1541b58ec8491489e24770`, the lane's parent was
`00ee5ccee14602a6b4711e76e2dbae635b8741b1`, and its implementation commit was
`dd76bff7aae1da81f99e98e1b5d1ac4fe390ff79`. The branch was **30 commits ahead**:
**29 inherited ancestors plus one VIEW integration commit**, not 30 VIEW commits.
Documentation successors add commits after that boundary without changing its
meaning. Verify current refs before a later integration decision.

The inherited history includes mirror capture/drain/read filtering, cache
isolation, grants, dependencies, migrations and deployment tooling. The lane
and its ancestors both touch `config/routes.rb`,
`mod/mcp_api/app/controllers/api/mcp/auth_controller.rb`, and
`mod/mcp_api/lib/mcp_api/atomspace_grants.rb`. Those are concrete semantic conflict
surfaces; other branches can also overlap lifecycle, TLS/session configuration
and mirror initialization. A blind merge or single-commit cherry-pick can both
lose required prerequisites. Do not consolidate during documentation closeout.

Before consolidation, reconcile:

1. Exact CONTRACT, STORE runtime/input and CLIENT import-closure versions.
2. The committed adapter experiment versus the actual Ruby runtime; they are not
   interchangeable implementations or evidence classes.
3. The copied CLIENT assets in this branch versus the CLIENT owner's later
   shipping entry point and modules. Publication of this branch did not silently
   synchronize those snapshots with the accepted DEV assets.
4. Compatible interpreter/dependencies, explicit reader invocation, Thin serving
   lifecycle, session/proxy protections and rollback, without modifying the
   preserved earlier sidecar or treating example/golden readers as live input.
5. A reproducible database-backed Decko test environment and an actual CI gate.

## Remaining work

The demonstrated bounded snapshot is not the finished specification. Priorities
are a tested continuous drain/freshness path; reproducible Rails/DB authorization
and cursor tests; honest and enforced limits (advertisement is not enforcement);
state/reload/retention and omission semantics; then measured scale and browser
latency. Refresh/live polling, full-schema exploration and optional backends are
not made complete by the prototype. Writes, production rollout and general-user
access are separate scope decisions.

The 2025 future-backend roadmap in `../ATOMSPACE-INTEGRATION.md` is historical,
not a claim that this prototype replaces PostgreSQL or supplies reasoning/MORK.
This closeout is documentation only and authorizes no operational action.
