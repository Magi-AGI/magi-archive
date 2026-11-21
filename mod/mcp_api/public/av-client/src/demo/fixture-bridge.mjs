/**
 * FIXTURE BRIDGE — lane E1 demo scaffolding.
 *
 * Fetches RECORDED I3 fixture files over HTTP and feeds them to the existing, tested
 * ingestion module (`../drawn-graph.mjs`), handing the renderer a frozen "scene": the
 * FULL ACCUMULATED graph views plus derived counts. It is a thin adapter and nothing more.
 *
 * WHAT THIS MODULE DELIBERATELY DOES NOT DO
 * -----------------------------------------
 *  - NO LAYOUT. `element.position` and `connection.position` are ALWAYS null coming out of
 *    ingestion and are passed through UNTOUCHED. No coordinate, camera, extent or default is
 *    invented here. Layout is a separate stage and is not this lane's.
 *  - NO BUDGETS, NO CAPS, NO CULLING. Every record the store reported is handed on.
 *  - NO POLLING, NO TIMERS, NO LIVE UPDATE. `limits.poll-interval-ms` is observed null in the
 *    recordings; this module neither defaults nor derives nor uses it, and contains no
 *    setInterval/setTimeout. Incremental change (I3-09) is lane E2 and is absent here.
 *  - NO MARKUP. Nothing in this module builds DOM or HTML. Every `labelFields[].text` is
 *    VERBATIM TEXT AS DATA — the recorded corpus contains `<script>alert("x")</script>` and
 *    an unterminated `<b`. Consumers MUST render label text with textContent /
 *    createTextNode only; concatenating it into innerHTML would execute the corpus.
 *
 * THE ONE INGESTION RULE THIS MODULE EXISTS TO PROTECT
 * ---------------------------------------------------
 * A link of arity >= 3 is reported ONCE PER NEIGHBOUR, and no single report shows its true
 * arity. Only the accumulated UNION of reported positions (`connection.knownPositions`) gives
 * the correct arity and therefore the correct drawn form. So every response is ingested into
 * ONE SHARED graph and the scene is re-read from `views(graph)` AFTER each ingest. Nothing
 * here recomputes arity; `drawn-graph.mjs` owns that union.
 *
 * IDENTITY IS key+digest, NEVER key ALONE. The same `key` legitimately appears several times
 * with different digests (a different recorded state of the same thing). See `elementIndex`
 * and the documented limitation on `firstElementByKey`.
 */

import {
  emptyDrawnGraph,
  ingestOpen,
  ingestNeighboursPage,
  views,
  fingerprint,
  identityOf,
} from '../drawn-graph.mjs';

/**
 * URL prefix the dev server maps to the READ-ONLY recorded fixture directory
 * (av-fixtures/lane-f/fixtures/recorded-i3/K8-draft-2/). See src/demo/server.py.
 *
 * ROOT-ABSOLUTE on purpose. The demo page is served from /src/demo/index.html, so a RELATIVE
 * 'fixtures/' would resolve against that directory and 404. Keep the leading slash.
 */
export const FIXTURE_BASE_DEFAULT = '/fixtures/';

// ============================================================================================
// CURATED DEMO SCENES
// ============================================================================================

/**
 * The curated `open` scenes, in presentation order. Every `file` here was verified to exist in
 * the recorded corpus. `note` says what is VISUALLY interesting, so the renderer author can
 * tell at a glance what each scene is meant to prove.
 *
 * @returns {ReadonlyArray<{id:string,file:string,title:string,note:string,kind:'open'}>}
 */
export function demoScenes() {
  return DEMO_SCENES;
}

const DEMO_SCENES = Object.freeze(
  [
    {
      id: 'three-participant-link',
      file: 'I3-02-open--beta-three-participant-link.json',
      title: 'Arity-3 link drawn as a node',
      note:
        'The headline ingestion case. An arity-3 link is reported once per neighbour, so no ' +
        'single report shows arity 3 — only the accumulated union of knownPositions does. ' +
        'Expect a connection with arity 3, drawnForm "link-node" and 3 spokes, plus a link ' +
        'that is itself a participant.',
    },
    {
      id: 'alpha-by-name-d0',
      file: 'I3-02-open--alpha-by-name-d0.json',
      title: 'Largest open scene (8 elements, 7 connections)',
      note:
        'The densest single open response in the corpus. Includes a class:"missing" ' +
        'placeholder (Card 999) — a thing the store named but could not resolve, which must ' +
        'be drawn as a placeholder rather than dropped or faked.',
    },
    {
      id: 'beta-distance-absent',
      file: 'I3-02-open--beta-distance-absent.json',
      title: 'Default load (distance absent)',
      note:
        'The dense default open with no distance narrowing supplied — what the viewer shows ' +
        'before the user narrows anything. Good baseline for visual comparison.',
    },
    {
      id: 'supports-link-by-key',
      file: 'I3-02-open--supports-link-by-key.json',
      title: 'A link opened as the focus (link as node)',
      note:
        'Entry class "link" with is-participant true: the store says the link is itself a ' +
        'participant, which forces a link NODE independently of arity. Proves drawn form ' +
        'comes from the store, not from counting.',
    },
    {
      id: 'theta-self-link',
      file: 'I3-02-open--theta-self-link.json',
      title: 'Self-link (loop)',
      note:
        'A link whose subject is its own neighbour (isSelfLink true, no neighbour positions). ' +
        'Needs a loop rendering rather than a straight segment between two distinct endpoints.',
    },
    {
      id: 'trashed-card',
      file: 'I3-02-open--trashed-card.json',
      title: 'Trashed participant (a STYLE, not a form)',
      note:
        'trash:true must change the STYLE of the element (dimmed/struck), never its drawn ' +
        'FORM and never its presence. A trashed thing is still part of the drawn graph.',
    },
    {
      id: 'hostile-script-name',
      file: 'I3-02-open--hostile-script-name.json',
      title: 'Text as data: literal <script> in a name',
      note:
        'The text-as-data proof. labelFields[].text contains script markup verbatim. It MUST ' +
        'render as the literal characters via textContent. If anything appears to execute, or ' +
        'the angle brackets vanish, the renderer is using innerHTML and is wrong.',
    },
    {
      id: 'compound-name-plus-slash-space',
      file: 'I3-02-open--compound-name-plus-slash-space.json',
      title: 'Compound name with + / and spaces',
      note:
        'Punctuation that is significant in URLs and in Decko names survives as plain label ' +
        'text. Nothing here is decoded, re-encoded or split on the separators.',
    },
    {
      id: 'alpha-degraded',
      file: 'I3-02-open--alpha-degraded.json',
      title: 'Outcome "degraded" — still draws',
      note:
        'A state-reporting outcome: the read happened and the content is real, but the store ' +
        'flags its own health. Draws normally; the degraded status belongs in a status strip, ' +
        'not in the graph geometry.',
    },
    {
      id: 'alpha-not-ready',
      file: 'I3-02-open--alpha-not-ready.json',
      title: 'Outcome "not ready" — ZERO drawn content',
      note:
        'A NO-STATE-READ outcome: contributesDrawnContent is false and the scene must be ' +
        'empty (0 elements, 0 connections). The epoch/position/read-at triple is ' +
        'present-and-each-exactly-null, so NO evidence age exists to display. The right ' +
        'rendering is an explicit "no state read" message, never a blank canvas that looks ' +
        'like an empty graph.',
    },
  ].map((s) => Object.freeze({ ...s, kind: 'open' })),
);

/**
 * The `ada created-by` neighbours pages in PAGE ORDER, for the "page through a bucket" demo.
 * Ingested one after another into ONE graph, they demonstrate monotone accumulation and
 * idempotent re-ingest. All six filenames were verified to exist.
 *
 * @returns {ReadonlyArray<string>}
 */
export function pagingWalk() {
  return PAGING_WALK;
}

const PAGING_WALK = Object.freeze([
  'I3-03-neighbours--ada-created-by-page-1.json',
  'I3-03-neighbours--ada-created-by-page-2.json',
  'I3-03-neighbours--ada-created-by-page-3.json',
  'I3-03-neighbours--ada-created-by-page-4.json',
  'I3-03-neighbours--ada-created-by-page-5.json',
  'I3-03-neighbours--ada-created-by-page-6.json',
]);

// ============================================================================================
// LOADING
// ============================================================================================

function joinUrl(baseUrl, file) {
  if (!baseUrl) return file;
  return baseUrl.endsWith('/') ? `${baseUrl}${file}` : `${baseUrl}/${file}`;
}

/**
 * Fetch and parse ONE fixture file.
 *
 * Returns the WRAPPER object as recorded: `{ recording, response }`. The wrapper's
 * `recording` is fixture METADATA and is NOT a wire body — only `.response` may be passed to
 * the ingestion entrypoints. Handing the whole wrapper to ingestOpen silently yields an empty
 * graph, so callers go through openScene/ingestPageInto rather than doing it by hand.
 *
 * @param {string} file
 * @param {string} [baseUrl]
 * @returns {Promise<{recording: object, response: object|null}>}
 */
export async function loadFixture(file, baseUrl = FIXTURE_BASE_DEFAULT) {
  const url = joinUrl(baseUrl, file);
  let res;
  try {
    res = await fetch(url);
  } catch (cause) {
    throw new Error(`fixture fetch failed for ${url}: ${cause && cause.message}`, { cause });
  }
  if (!res.ok) {
    throw new Error(`fixture fetch failed for ${url}: HTTP ${res.status} ${res.statusText}`);
  }
  const text = await res.text();
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch (cause) {
    throw new Error(`fixture JSON parse failed for ${url}: ${cause && cause.message}`, { cause });
  }
  if (!parsed || typeof parsed !== 'object') {
    throw new Error(`fixture at ${url} is not an object`);
  }
  if (!('response' in parsed)) {
    throw new Error(
      `fixture at ${url} has no "response" key; the wrapper must be { recording, response }`,
    );
  }
  return parsed;
}

/**
 * Load an `open` fixture into a FRESH graph. An `open` response is a whole read, so it starts
 * a new graph rather than merging into an existing one.
 *
 * @param {string} file
 * @param {string} [baseUrl]
 */
export async function openScene(file, baseUrl = FIXTURE_BASE_DEFAULT) {
  const wrapper = await loadFixture(file, baseUrl);
  const graph = emptyDrawnGraph();
  const result = ingestOpen(wrapper.response, graph);
  return {
    graph,
    result,
    file,
    recording: wrapper.recording ?? null,
    response: wrapper.response,
    scene: sceneFrom(graph, result),
  };
}

/**
 * Merge a `neighbours` PAGE into an EXISTING graph, then re-read the whole scene.
 *
 * The re-read is the point: a page can RAISE the arity of a link already drawn (the union
 * grows), which can turn a line into a link node. Rendering only the page's own records would
 * miss that.
 *
 * `result.cursorStale` is surfaced untouched. A stale cursor is reported, never silently
 * healed — the paging policy is the caller's.
 *
 * @param {object} graph  a graph from emptyDrawnGraph()/openScene()
 * @param {string} file
 * @param {string} [baseUrl]
 */
export async function ingestPageInto(graph, file, baseUrl = FIXTURE_BASE_DEFAULT) {
  if (!graph) throw new TypeError('ingestPageInto needs an existing graph; pass one');
  const wrapper = await loadFixture(file, baseUrl);
  const result = ingestNeighboursPage(wrapper.response, graph);
  return { graph, result, scene: sceneFrom(graph, result) };
}

// ============================================================================================
// SCENE
// ============================================================================================

/**
 * Build the frozen scene the renderer consumes.
 *
 * `elements` / `connections` / `buckets` are RE-READ FRESH from views(graph) and are the FULL
 * ACCUMULATED graph, not just the last response's contribution. Records are passed through
 * exactly as ingestion froze them — same field names, same null positions.
 *
 * Counts are computed by ITERATING the arrays, never assumed from the wire counts (a bucket's
 * `counts` describe the store's extent, which is not the same as what has been ingested).
 *
 * @param {object} graph
 * @param {object} lastResult  the result object from the most recent ingest
 */
export function sceneFrom(graph, lastResult) {
  const { elements, connections, buckets } = views(graph);

  let drawnBuckets = 0;
  for (const b of buckets) if (b.drawn) drawnBuckets += 1;

  let lineConnections = 0;
  let linkNodeConnections = 0;
  let highArityConnections = 0;
  for (const c of connections) {
    if (c.drawnForm === 'link-node') linkNodeConnections += 1;
    else if (c.drawnForm === 'line') lineConnections += 1;
    // Arity is the size of the accumulated position union; >= 3 cannot be drawn as a single
    // segment between two endpoints.
    if (c.arity >= 3) highArityConnections += 1;
  }

  const envelope = lastResult ? lastResult.envelopeState ?? null : null;
  const classification = lastResult ? lastResult.classification ?? null : null;

  return Object.freeze({
    elements,
    connections,
    buckets,

    envelopeState: envelope,
    classification,
    stats: lastResult ? lastResult.stats ?? null : null,

    counts: Object.freeze({
      elements: elements.length,
      connections: connections.length,
      buckets: buckets.length,
      drawnBuckets,
      lineConnections,
      linkNodeConnections,
      highArityConnections,
    }),

    // The single source of the label-bearing SET, straight off the envelope's limits block.
    // MAY BE NULL (no-state-read responses carry no limits); consumers must handle null and
    // must not substitute a hardcoded list.
    labelBearingProperties: envelope ? envelope.labelBearingProperties ?? null : null,

    outcome: envelope ? envelope.outcome ?? null : null,
    contributesDrawnContent: classification ? classification.contributesDrawnContent : false,

    fingerprint: fingerprint(graph),
  });
}

// ============================================================================================
// INDEXES FOR THE RENDERER
// ============================================================================================

/**
 * identityOf(element) -> array index, for resolving a record to its slot in the scene arrays.
 * Identity is key+digest: this is the CORRECT index and the one to prefer.
 *
 * @param {ReadonlyArray<object>} elements
 * @returns {Map<string, number>}
 */
export function elementIndex(elements) {
  const index = new Map();
  for (let i = 0; i < elements.length; i += 1) index.set(identityOf(elements[i]), i);
  return index;
}

/**
 * element.key -> FIRST array index with that key.
 *
 * WHY THIS EXISTS, AND THE LIMITATION IT CARRIES — READ BEFORE USING.
 *
 * `connection.spokes` and `connection.participants[].key` are BARE KEYS: the wire does not
 * give a digest for a link's participants. But element identity is key+digest, and the same
 * key legitimately appears MORE THAN ONCE with different digests (different recorded states
 * of the same thing). So a spoke cannot be resolved to a unique element in general.
 *
 * This map is a DEMO-LEVEL resolution of that key-vs-identity mismatch: when a key has
 * several digests it resolves to the FIRST in the deterministic sort order. That choice is
 * arbitrary and may attach a spoke to the wrong state of the right thing.
 *
 * This is a REAL PROTOCOL LIMITATION TO REPORT UPWARDS, not a silent implementation choice.
 * Anything beyond a demo needs either digest-bearing participant references on the wire or an
 * explicit disambiguation rule. Use `keyCollisions` to surface where it actually bites.
 *
 * @param {ReadonlyArray<object>} elements
 * @returns {Map<string, number>}
 */
export function firstElementByKey(elements) {
  const index = new Map();
  for (let i = 0; i < elements.length; i += 1) {
    const k = elements[i].key;
    if (!index.has(k)) index.set(k, i);
  }
  return index;
}

/**
 * Keys carrying MORE THAN ONE digest in this scene, i.e. exactly where firstElementByKey's
 * first-wins resolution is ambiguous. Report these rather than hiding them.
 *
 * @param {ReadonlyArray<object>} elements
 * @returns {Array<{key: string, digests: string[]}>}
 */
export function keyCollisions(elements) {
  const byKey = new Map();
  for (const e of elements) {
    if (!byKey.has(e.key)) byKey.set(e.key, []);
    byKey.get(e.key).push(e.digest);
  }
  const out = [];
  for (const [key, digests] of byKey) if (digests.length > 1) out.push({ key, digests });
  return out;
}

// ============================================================================================
// DEMO-LEVEL NARROWING
// ============================================================================================

/**
 * Filter buckets that have ALREADY BEEN RECORDED AND INGESTED.
 *
 * THIS IS NOT PROTOCOL NARROWING. Real narrowing (kind / card-type / direction, cp030 §7.5 R6)
 * is SENT WITH the open/neighbours REQUEST and changes what the store reads and returns — it
 * is a server-side operation. It is NOT implemented here because it requires live requests,
 * and live request construction is lane E2's. What this function does is hide already-loaded
 * buckets from view; it cannot reveal anything the recording did not contain, and it must not
 * be presented in the UI as if it were protocol narrowing.
 *
 * @param {ReadonlyArray<object>} buckets
 * @param {{linkType?: string|null, drawnOnly?: boolean}} [options]
 * @returns {Array<object>}
 */
export function narrowBuckets(buckets, { linkType = null, drawnOnly = false } = {}) {
  const out = [];
  for (const b of buckets) {
    if (linkType !== null && b.linkType !== linkType) continue;
    if (drawnOnly && !b.drawn) continue;
    out.push(b);
  }
  return out;
}
