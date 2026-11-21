// The AtomSpace Visualizer CLIENT's DRAWN-GRAPH MODEL — lane E1, INGESTION HALF.
//
// ============================================================================================
// HEADER — WHAT THIS IS, WHAT IT IS CODED AGAINST, WHAT IT SETTLES
// ============================================================================================
// Coded against K8-draft-2 + k8-draft-2-addendum-1 — **WORKING DRAFT 2, NOT FROZEN**.
// Re-point this file on announced changes to either document. Every wire field consumed below
// is EXACT-marked in K8-draft-2 (§5.3 outcomes, §5.6 buckets/counts/entry classes/
// `is-participant`, §5.8 `omitted`, the I3-02/I3-03 payload rows of §5.5) or is cp030 §7.2's /
// §7.1's drawn-form and fallback rules. Nothing else is consumed and nothing is derived from a
// field this client was not given.
//
// THIS IS THE INGESTION HALF OF E1. It is:
//   - NOT a renderer. It draws nothing, opens no canvas, touches no WebGPU, emits no markup.
//   - NOT lane E2. The layout stage is E2's and is not assigned here.
//   - NOT M2. E1-plus-ingestion does not constitute M2; M2 additionally needs lane E2.
//   - SETTLING NOTHING RESERVED TO LAKE: not D42 (whether GPU compute-shader layout stands),
//     not the drawing budgets P-DRAW-ELEM / P-DRAW-CONN (cp030 §7.4's 300/900 are explicitly
//     "starting figures, replaced by measurement" and are NOT hard-coded anywhere in this
//     file), not 2D-vs-3D, not the S-legibility thresholds, not the polling interval. None of
//     those values appears here, as a constant or as a derivation.
//
// PROVENANCE IS OMITTED ON EVERY PATH (V07, V09-family). This module has no provenance record
// type, no provenance field, and no code path that could place one in a drawn graph. K8-draft-2
// §5.7 is EXACT that no I3 endpoint ever returns a provenance record, and that a direct request
// for one answers `excluded` with a reason only; that `excluded` envelope is handled here like
// any other non-state-reporting outcome — it contributes NO drawn content, and its reason is
// not drawn.
//
// TEXT FROM THE SPACE IS DATA, NEVER MARKUP (V07, V09-family). Every label field is carried as
// a PLAIN STRING, verbatim as recorded. This module never escapes, wraps, concatenates into,
// or emits markup, and never produces an HTML string. A consumer must bind these strings as
// text nodes / text content. The recorded set contains hostile names (`<script>alert("x")
// </script>`, `Unterminated <b`, `]]> &#x3c; ${x} {{y}}`) precisely so this stays provable.
//
// ZERO DEPENDENCIES: node builtins only, and in fact nothing but ./presentation-registry.mjs.

import {
  DRAWN_FORMS,
  GENERIC_PROPERTY_LABEL_ORDER,
  GENERIC_STRUCTURAL_LABEL_ORDER,
  lookupByDeclaredHead,
  orderPropertyLabelFields,
  orderStructuralLabelFields,
} from './presentation-registry.mjs';

export { DRAWN_FORMS };

// ============================================================================================
// NORMATIVE VOCABULARY FROM THE WIRE
// ============================================================================================

/** K8-draft-2 §5.6, EXACT: these seven strings are normative. */
export const ENTRY_CLASSES = Object.freeze([
  'entity',
  'link',
  'unresolved',
  'missing',
  'declaration',
  'malformed',
  'data',
]);

/** K8-draft-2 §5.3, EXACT: the complete set. Nine rows, no tenth. */
export const OUTCOMES = Object.freeze([
  'ok',
  'ok, partial',
  'empty',
  'unknown',
  'excluded',
  'not ready',
  'degraded',
  'unavailable',
  'reload',
]);

/**
 * The outcomes that REPORT STATE — i.e. whose payload can contribute drawn content.
 *
 * Grounded in §5.3's own Payload column: `ok` -> full, `ok, partial` -> partial + `omitted`,
 * `degraded` -> "full + health". The other six carry no participant/bucket/entry payload:
 * `empty`, `unknown`, `reload` -> none; `excluded` -> the reason only; `not ready`,
 * `unavailable` -> `health` (if known). The recordings agree exactly: every I3-02/I3-03
 * envelope with a `participant` block has one of these three outcomes, and every envelope with
 * one of the other six has no participant, no buckets and no entries.
 *
 * `not ready` and `unavailable` are additionally the two NO-STATE-READ outcomes: under the
 * SETTLED O20 rule (K8-draft-2 §5.2) their `epoch`, `position` and `read-at` are all three
 * PRESENT and each exactly null, and no evidence age may be taken from them. See
 * NO_STATE_READ_OUTCOMES and the envelopeState() block.
 */
export const STATE_REPORTING_OUTCOMES = Object.freeze(['ok', 'ok, partial', 'degraded']);

/**
 * How a response was classified. `refusal-no-envelope` is NOT an outcome and no outcome is
 * invented for it: K8-draft-2 §5.1 hands a refusal to Decko's unknown-path handler, whose
 * status and body are K9's and are not recorded, so the recorded `response` is literally null.
 * `unrecognised-outcome` is §5.3's AMENDED rule: a protocol violation, not an outcome.
 */
export const RESPONSE_KINDS = Object.freeze({
  stateReporting: 'state-reporting',
  noStateContent: 'no-state-content',
  refusalNoEnvelope: 'refusal-no-envelope',
  unrecognisedOutcome: 'unrecognised-outcome',
});

// ============================================================================================
// THE POSITION SLOT — OWNED BY THE LAYOUT STAGE, NEVER BY INGESTION
// ============================================================================================

/**
 * EVERY element and link-node carries this slot, and INGESTION ALWAYS LEAVES IT null.
 *
 * WHO OWNS IT: the LAYOUT STAGE (lane E2), not this module.
 *
 * WHY IT IS null HERE AND NOT A DEFAULT, A SEED OR A ZERO:
 *   - No I3 endpoint carries any coordinate. An exhaustive key walk over all 123 recorded files
 *     found zero x/y/z/pos/coords/layout keys, BY DESIGN. Positions are the client's to
 *     compute.
 *   - WHAT COMPUTES THEM IS DECISION **D42**, which is **RESERVED TO LAKE** and is UNSETTLED.
 *     D42 is whether force-directed layout runs in GPU compute shaders (cp030 §7.3). Spike
 *     S-gpu measured that it can on one machine and says in its own result that "a spike
 *     discharges no guarantee" and "Lake's ruling is still required".
 *   - So ingestion NEITHER SUPPLIES NOR ASSUMES COORDINATES. It does not seed a position, does
 *     not pick an origin, does not imply 2D or 3D (also Lake's), and does not provide a CPU
 *     fallback — choosing the fallback is Lake's call, not this lane's.
 *
 * A reader can therefore assert, over the whole recorded set, that `position === null`
 * everywhere after ingestion. That assertion is a lane boundary made testable.
 */
export const UNSET_POSITION = null;

/**
 * The STORE HISTORY position is a different thing entirely and is never confused with geometry.
 * K8-draft-2's envelope `position` is the store history position, never a geometric position;
 * it is carried in the envelope-derived state below under `storePosition`.
 */

// ============================================================================================
// IDENTITY
// ============================================================================================

/**
 * Identity is ALWAYS from the wire. K8-draft-2: every participant and every link carries `key`
 * + `digest`; A CLIENT NEVER CONSTRUCTS EITHER. This module reads both and synthesises neither.
 *
 * @param {object} wireThing
 * @param {string} where  for the error message
 */
function wireIdentity(wireThing, where) {
  const key = wireThing?.key;
  const digest = wireThing?.digest;
  if (typeof key !== 'string') {
    throw new TypeError(`${where}: no wire \`key\`; a client never constructs one`);
  }
  if (typeof digest !== 'string') {
    throw new TypeError(`${where}: no wire \`digest\`; a client never constructs one`);
  }
  return { key, digest };
}

/** The identity pair a merge is idempotent on. */
export function identityOf(record) {
  return `${record.key}\u0000${record.digest}`;
}

// ============================================================================================
// LABELS
// ============================================================================================

/**
 * The label FORM a wire label block is in.
 *
 * K8-draft-2 gives two: {name, type-name} for entities, and {head, parts} for class 'missing'.
 * The recordings show the structural {head, parts} form is used for 'missing', 'unresolved' AND
 * 'link' — which is consistent, since cp030 §7.2 labels each of those by head and parts — and
 * show no third form and no label block absent from any entry.
 */
export const LABEL_FORMS = Object.freeze({
  properties: 'properties', // {name, type-name}
  structural: 'structural', // {head, parts}
  none: 'none', // no label block on the wire (I3-03's participant stub)
});

function labelFormOf(labelBlock) {
  if (!labelBlock || typeof labelBlock !== 'object') return LABEL_FORMS.none;
  const hasStructural =
    Object.prototype.hasOwnProperty.call(labelBlock, 'head') ||
    Object.prototype.hasOwnProperty.call(labelBlock, 'parts');
  if (hasStructural) return LABEL_FORMS.structural;
  const hasProperty =
    Object.prototype.hasOwnProperty.call(labelBlock, 'name') ||
    Object.prototype.hasOwnProperty.call(labelBlock, 'type-name');
  if (hasProperty) return LABEL_FORMS.properties;
  return LABEL_FORMS.none;
}

/**
 * Build the ordered label FIELDS, as plain strings.
 *
 * The label-bearing property SET comes from the response envelope's
 * `limits.label-bearing-properties` and from NOWHERE ELSE — K10 §3.4: the SET is on the wire and
 * the registry keeps NO copy; a registry entry supplies only the ORDER. This function is
 * therefore given the wire set explicitly and has no default for it.
 */
function buildLabel(labelBlock, labelBearingFromWire, registryEntry) {
  const form = labelFormOf(labelBlock);
  if (form === LABEL_FORMS.structural) {
    return {
      form,
      fields: orderStructuralLabelFields(labelBlock, GENERIC_STRUCTURAL_LABEL_ORDER),
    };
  }
  if (form === LABEL_FORMS.properties) {
    const order = registryEntry.propertyLabelOrder ?? GENERIC_PROPERTY_LABEL_ORDER;
    return {
      form,
      fields: orderPropertyLabelFields(labelBlock, labelBearingFromWire, order),
    };
  }
  return { form, fields: [] };
}

// ============================================================================================
// DECLARED HEAD — what registry lookup is keyed by
// ============================================================================================

/**
 * The DECLARED HEAD used for registry lookup (cp030 §7.1 keys the registry by declared head).
 *
 * For a structural label the head IS on the wire, in `label.head` — the recordings show
 * `"Card"` for a missing card, `"Wanted"` for an unresolved target, `"supports"` for a link.
 *
 * For a property-form (entity) label there is NO head field on the wire. This module reports
 * null rather than inventing one: it does not assume the constructor is `Card`, because the
 * entity class covers more than cards and nothing in the EXACT-marked wire fields states the
 * constructor. A null head is a well-defined registry lookup — it takes the normative generic
 * fallback (cp030 §7.1: "A head with no entry falls back to the generic form"), which is the
 * same answer the empty registry gives for every other head today.
 *
 * NAMED GAP, OWNER COORDINATOR: if E2 or the inspector needs an entity's declared constructor
 * head, that is either a wire addition (CONTRACT's) or a registry-keying clarification
 * (coordinator's). It is not derivable here and is not guessed.
 */
function declaredHeadOf(labelBlock, linkType) {
  if (typeof linkType === 'string') return linkType;
  if (labelBlock && typeof labelBlock === 'object' && typeof labelBlock.head === 'string') {
    return labelBlock.head;
  }
  return null;
}

// ============================================================================================
// DRAWN FORM RESOLUTION — cp030 §7.2, and §7.1's generic fallback
// ============================================================================================

/**
 * Resolve an ELEMENT's drawn form from its entry class, per cp030 §7.2.
 *
 *   entity                      -> element    ("an element, labelled per its entry; a card by
 *                                               name and type name" R17)
 *   unresolved                  -> stub       ("a stub from its source, labelled with the
 *                                               wanted key" R7)
 *   missing                     -> placeholder("a placeholder element, visibly distinct")
 *   declaration/malformed/data  -> generic    ("an atom of undeclared kind, a bare symbol, a
 *                                               grounded value, an empty expression -> a
 *                                               generic element" R26/R17)
 *   link                        -> line or link-node, by the CONNECTION rule below; as an
 *                                  ELEMENT record a link is only ever a link-node, since a
 *                                  link that is itself a participant draws as a link node.
 *
 * TRASH IS A STYLE, NOT A FORM. cp030 §7.2: "a trashed card -> an element in a distinct style".
 * A trashed card is still an element; `trash` is carried on the record so the (unadopted)
 * styling can be applied by whoever owns style. This module assigns no style.
 *
 * An unrecognised class is NOT silently generic-ed: the seven strings are normative, so an
 * eighth is a protocol violation and is reported as such rather than drawn.
 */
export function resolveElementForm(entryClass, { isParticipant = false } = {}) {
  switch (entryClass) {
    case 'entity':
      return DRAWN_FORMS.element;
    case 'unresolved':
      return DRAWN_FORMS.stub;
    case 'missing':
      return DRAWN_FORMS.placeholder;
    case 'declaration':
    case 'malformed':
    case 'data':
      return DRAWN_FORMS.generic;
    case 'link':
      // A link appearing as a drawn THING (a focus participant, or a bucket entry that is
      // itself a link) is a link node: §7.2's link-node row covers "a link that is itself a
      // participant in another link", and a link reached as a neighbour "is a neighbour like
      // any other and has a neighbourhood of its own" (§5.6 N03). Its own 2-vs->=3 arity
      // governs the CONNECTION it draws, not the element it is.
      return isParticipant ? DRAWN_FORMS.linkNode : DRAWN_FORMS.linkNode;
    default:
      return null; // unrecognised class: reported, never drawn
  }
}

/**
 * Resolve a CONNECTION's drawn form by the NORMATIVE rule:
 *
 *   exactly 2 participants AND not itself a participant  -> 'line'
 *   >=3 participants OR is-participant true              -> 'link-node' (a spoke per participant)
 *
 * This is cp030 §7.2's two link rows verbatim. `is-participant` comes from the wire and is
 * never derived — K8-draft-2 §5.6 is EXACT that it is on the wire because "whether a stored
 * link is a participant of another link depends on what else is stored" and K10 §3.5 states the
 * client "cannot decide it from what it holds".
 *
 * ARITY is counted as the number of DISTINCT PARTICIPANT POSITIONS the link occupies, taken as
 * the union of `subject-positions` and `neighbour-positions`. K8-draft-2 §5.6 N03 is EXACT that
 * "a link's participants are counted by position": `(links-to (Card 7) (Card 7) "k")` has TWO
 * participant positions even though it reaches one neighbour, and is drawn as a loop — so
 * position-counting, not distinct-key-counting, is the rule. A self-link in the recordings
 * carries subject-positions [1,2] and neighbour-positions [], giving arity 2, a line (loop).
 *
 * @param {ReadonlyArray<number>} positions  union of subject + neighbour positions
 * @param {boolean} isParticipant            the wire boolean
 */
export function resolveConnectionForm(positions, isParticipant) {
  if (typeof isParticipant !== 'boolean') {
    throw new TypeError('`is-participant` must be the wire boolean; it is never derived');
  }
  const arity = new Set(positions).size;
  if (isParticipant) return DRAWN_FORMS.linkNode;
  if (arity >= 3) return DRAWN_FORMS.linkNode;
  return DRAWN_FORMS.line;
}

// ============================================================================================
// THE RECORDS
// ============================================================================================

/**
 * THE ELEMENT RECORD.
 *
 * @typedef {object} DrawnElement
 * @property {string} key            wire identity — never constructed
 * @property {string} digest         wire identity — never constructed
 * @property {string} entryClass     one of ENTRY_CLASSES (wire `class`)
 * @property {boolean|null} trash    wire `trash` (null where the wire has no trash state)
 * @property {'properties'|'structural'|'none'} labelForm
 * @property {ReadonlyArray<{property: string, text: string}>} labelFields
 *           ORDERED label fields as PLAIN STRINGS — text as data, never markup, never
 *           interpolated into markup.
 * @property {string|null} declaredHead  what registry lookup is keyed by (cp030 §7.1)
 * @property {string} drawnForm      element | stub | placeholder | generic | link-node (§7.2)
 * @property {boolean|null} isParticipant  wire `is-participant` where the thing is a link
 * @property {null} position         THE LAYOUT STAGE'S SLOT. Always null out of ingestion.
 * @property {boolean} isFocusParticipant  true for the response's own `participant`
 * @property {string|null} unrecognisedClass  set when `class` is outside the normative seven
 */
function makeElement({
  wire,
  labelBearingFromWire,
  isFocusParticipant,
  where,
}) {
  const { key, digest } = wireIdentity(wire, where);
  const entryClass = wire.class;
  const linkTypeForHead = undefined; // an element is never keyed by a joining link's type
  const declaredHead = declaredHeadOf(wire.label, linkTypeForHead);
  const registryEntry = lookupByDeclaredHead(declaredHead);
  const { form, fields } = buildLabel(wire.label, labelBearingFromWire, registryEntry);
  const isParticipant =
    typeof wire['is-participant'] === 'boolean' ? wire['is-participant'] : null;
  const drawnForm = resolveElementForm(entryClass, {
    isParticipant: isParticipant === true,
  });
  return Object.freeze({
    key,
    digest,
    entryClass: typeof entryClass === 'string' ? entryClass : null,
    trash: typeof wire.trash === 'boolean' ? wire.trash : null,
    labelForm: form,
    labelFields: Object.freeze(fields),
    declaredHead,
    drawnForm,
    isParticipant,
    // THE LAYOUT STAGE OWNS THIS. D42 (Lake, unsettled) decides what computes it. Ingestion
    // neither supplies nor assumes coordinates.
    position: UNSET_POSITION,
    isFocusParticipant: Boolean(isFocusParticipant),
    unrecognisedClass:
      typeof entryClass === 'string' && ENTRY_CLASSES.includes(entryClass) ? null : String(entryClass),
  });
}

/**
 * THE CONNECTION RECORD.
 *
 * @typedef {object} DrawnConnection
 * @property {string} key            wire identity — never constructed
 * @property {string} digest         wire identity — never constructed
 * @property {string} linkType       wire `link-type`
 * @property {ReadonlyArray<{key: string, role: 'subject'|'neighbour', positions: number[]}>}
 *           participants  the participant KEYS with their subject/neighbour positions
 * @property {ReadonlyArray<number>} subjectPositions   wire, the subject's positions
 * @property {ReadonlyArray<number>} neighbourPositions wire, the neighbour's positions
 * @property {ReadonlyArray<number>} knownPositions  the UNION of every participant position
 *           this client has been told about for this link, across all reports and pages.
 *           Arity and drawn form are computed from THIS, not from one report — see
 *           mergeConnection's note on why one report cannot show a link's full arity.
 * @property {number} arity          distinct participant positions (§5.6 N03)
 * @property {number|null} copyCount wire `copy-count`
 * @property {boolean} isParticipant wire `is-participant` — never derived
 * @property {string} drawnForm      'line' | 'link-node'
 * @property {ReadonlyArray<string>} spokes  one spoke per participant KEY when 'link-node';
 *                                           empty for a 'line' (§7.2: "a spoke to each
 *                                           participant")
 * @property {string|null} declaredHead  the link type, which IS the declared head for lookup
 * @property {boolean} isSelfLink    recorded in the bucket's `self-links`, or no neighbour
 *                                   position (a loop, §5.6 N03)
 * @property {null} position         THE LAYOUT STAGE'S SLOT. Always null out of ingestion.
 */
function makeConnection({ wire, subjectKey, neighbourKey, isSelfLink, where }) {
  const { key, digest } = wireIdentity(wire, where);
  const subjectPositions = Array.isArray(wire['subject-positions']) ? [...wire['subject-positions']] : [];
  const neighbourPositions = Array.isArray(wire['neighbour-positions'])
    ? [...wire['neighbour-positions']]
    : [];
  const allPositions = [...subjectPositions, ...neighbourPositions];
  const isParticipant = wire['is-participant'];
  const drawnForm = resolveConnectionForm(allPositions, isParticipant);

  const participants = [];
  if (typeof subjectKey === 'string') {
    participants.push(
      Object.freeze({ key: subjectKey, role: 'subject', positions: Object.freeze(subjectPositions) }),
    );
  }
  if (typeof neighbourKey === 'string' && neighbourPositions.length > 0) {
    participants.push(
      Object.freeze({ key: neighbourKey, role: 'neighbour', positions: Object.freeze(neighbourPositions) }),
    );
  }

  // §7.2: a link node gets "a spoke to each participant". The spokes are the participant KEYS
  // this response named. A link of arity >= 3 may name fewer participants in ONE response than
  // its arity (a 3-participant link appears once per neighbour entry), so spokes are MERGED
  // across pages by mergeConnection below rather than fabricated here.
  const spokes = drawnForm === DRAWN_FORMS.linkNode ? participants.map((p) => p.key) : [];

  return Object.freeze({
    key,
    digest,
    linkType: typeof wire['link-type'] === 'string' ? wire['link-type'] : null,
    participants: Object.freeze(participants),
    subjectPositions: Object.freeze(subjectPositions),
    neighbourPositions: Object.freeze(neighbourPositions),
    knownPositions: Object.freeze([...new Set(allPositions)].sort((a, b) => a - b)),
    arity: new Set(allPositions).size,
    copyCount: typeof wire['copy-count'] === 'number' ? wire['copy-count'] : null,
    isParticipant,
    drawnForm,
    spokes: Object.freeze(spokes),
    declaredHead: typeof wire['link-type'] === 'string' ? wire['link-type'] : null,
    isSelfLink: Boolean(isSelfLink) || neighbourPositions.length === 0,
    // THE LAYOUT STAGE OWNS THIS. See UNSET_POSITION.
    position: UNSET_POSITION,
  });
}

// ============================================================================================
// THE DRAWN GRAPH
// ============================================================================================

/**
 * @typedef {object} DrawnGraph
 * @property {Map<string, DrawnElement>} elements      keyed by `key\0digest`
 * @property {Map<string, DrawnConnection>} connections keyed by `key\0digest`
 * @property {Map<string, DrawnBucket>} buckets        keyed by participant key + link type +
 *                                                     narrowing
 * @property {EnvelopeState|null} envelopeState        envelope-derived state of the last ingest
 * @property {Array<object>} ingestLog                 one entry per ingested response
 */
export function emptyDrawnGraph() {
  return {
    elements: new Map(),
    connections: new Map(),
    buckets: new Map(),
    envelopeState: null,
    ingestLog: [],
  };
}

/**
 * ENVELOPE-DERIVED STATE. The envelope is on EVERY response: outcome, epoch, position,
 * read-at, schema-version, limits, health.
 *
 * `storePosition` is named so because K8-draft-2's `position` is the STORE HISTORY position,
 * NEVER a geometric position. Nothing in this module may read it as geometry.
 *
 * `labelBearingProperties` is carried through from `limits.label-bearing-properties` as the
 * single source of the label-bearing SET (K10 §3.4). It is read per response and not cached
 * beyond the state record.
 *
 * The POLLING INTERVAL is Lake's and unsettled: `limits.poll-interval-ms` is reported here as
 * it was received (observed null in the recordings) and this module neither defaults it,
 * derives it, nor polls.
 *
 * ------------------------------------------------------------------------------------------
 * O20 — SETTLED (K8-draft-2 §5.2). DELIBERATE RULING-DRIVEN UPDATE, NOT A SILENT REBASELINE.
 * ------------------------------------------------------------------------------------------
 * For the two NO-STATE-READ outcomes `not ready` and `unavailable`, the envelope fields
 * `epoch`, `position` and `read-at` MUST ALL THREE BE PRESENT and each be exactly JSON null.
 * Omitting any of them, or a mix of present and omitted, is NON-CONFORMING. `epoch` is null on
 * `not ready` too: a known bootstrap epoch is NOT reported. The ABSENT form, previously a live
 * candidate while O20 was open, is no longer a candidate.
 *
 * Consequence this module must honour: NO EVIDENCE AGE may be taken from such a response —
 * `read-at` null means no read instant exists, so there is nothing to subtract. The HEALTH
 * block keeps its own instants (`as-of` / `reported-at`, and a not-ready status's
 * `drain-heartbeat-at`) under its OWN rules, and they are NOT evidence of a state read; this
 * module never promotes one into a state-read instant. No age is computed anywhere here.
 *
 * WHY PRESENCE IS READ WITH Object.hasOwn AND NOT `??`: `??` maps BOTH absent and
 * present-and-null to null, which under the settled rule are a NON-CONFORMING and a CONFORMING
 * envelope respectively. The derived values stay identical (null either way), but the
 * distinction is now reportable instead of being silently flattened.
 *
 * @typedef {object} EnvelopeState
 */

/** The outcomes that read NO state at all, so carry no read instant (K8-draft-2 §5.2 / §5.3). */
export const NO_STATE_READ_OUTCOMES = Object.freeze(['not ready', 'unavailable']);

const hasOwn = (o, k) => Object.prototype.hasOwnProperty.call(o, k);

function envelopeState(response) {
  const limits = response.limits ?? null;
  const lbp = limits ? limits['label-bearing-properties'] : undefined;

  // O20, settled: presence is read separately from value, for the reason above.
  const epochPresent = hasOwn(response, 'epoch');
  const storePositionPresent = hasOwn(response, 'position');
  const readAtPresent = hasOwn(response, 'read-at');
  const outcome = response.outcome ?? null;
  const noStateRead = NO_STATE_READ_OUTCOMES.includes(outcome);
  const tripleAllPresentAndNull =
    epochPresent &&
    storePositionPresent &&
    readAtPresent &&
    response.epoch === null &&
    response.position === null &&
    response['read-at'] === null;

  return Object.freeze({
    outcome,
    epoch: response.epoch ?? null,
    storePosition: response.position ?? null, // store HISTORY position, never geometry
    readAt: response['read-at'] ?? null,

    // --- O20 (settled) reporting. Observation only: nothing here is drawn or defaulted. ---
    /** True for `not ready` / `unavailable`: the response read no state. */
    noStateRead,
    /** Presence as OWN PROPERTIES, distinguishing present-and-null from absent. */
    noStateReadTriple: Object.freeze({
      epochPresent,
      positionPresent: storePositionPresent,
      readAtPresent,
      /** The settled conforming form: all three present, each exactly null. */
      allPresentAndNull: tripleAllPresentAndNull,
    }),
    /**
     * True iff no evidence age may be taken from this response (the §5.2 invariant for the
     * two no-state-read outcomes). False does NOT assert an age is computable — this module
     * computes no age at all; evidence age is not this lane's to define.
     */
    evidenceAgeUnavailable: noStateRead,
    schemaVersion: response['schema-version'] ?? null,
    labelBearingProperties: Array.isArray(lbp) ? Object.freeze([...lbp]) : null,
    pollIntervalMs: limits && 'poll-interval-ms' in limits ? limits['poll-interval-ms'] : null,
    healthPresent: Object.prototype.hasOwnProperty.call(response, 'health'),
    cursorStale: 'cursor-stale' in response ? response['cursor-stale'] : null,
    omitted: response.omitted ?? null,
    limits: limits ? Object.freeze({ ...limits }) : null,
  });
}

/** Classify a recorded response. A null response is a refusal/414, NOT an outcome. */
export function classifyResponse(response) {
  if (response === null || response === undefined) {
    return {
      kind: RESPONSE_KINDS.refusalNoEnvelope,
      outcome: null,
      contributesDrawnContent: false,
      note:
        'a refusal or 414 has a NULL response body: no envelope, no outcome. No outcome is ' +
        'invented for it (K8-draft-2 §5.1 hands it to Decko\u2019s unknown-path handler).',
    };
  }
  const outcome = response.outcome ?? null;
  if (!OUTCOMES.includes(outcome)) {
    return {
      kind: RESPONSE_KINDS.unrecognisedOutcome,
      outcome,
      contributesDrawnContent: false,
      note:
        'an outcome the client does not recognise is a PROTOCOL VIOLATION, not an outcome ' +
        '(K8-draft-2 §5.3 as amended): the client draws nothing from the response.',
    };
  }
  if (STATE_REPORTING_OUTCOMES.includes(outcome)) {
    return { kind: RESPONSE_KINDS.stateReporting, outcome, contributesDrawnContent: true, note: null };
  }
  return {
    kind: RESPONSE_KINDS.noStateContent,
    outcome,
    contributesDrawnContent: false,
    note: `outcome \`${outcome}\` carries no participant/bucket/entry payload (K8-draft-2 §5.3)`,
  };
}

// ---------------------------------------------------------------------------- bucket records

function bucketIdentity(participantKey, wireBucket) {
  const narrowing = wireBucket.narrowing ?? {};
  const n = [
    (narrowing.kind ?? []).join('+'),
    (narrowing['card-type'] ?? []).join('+'),
    (narrowing.direction ?? []).join('+'),
  ].join('|');
  return `${participantKey}\u0000${wireBucket['link-type']}\u0000${n}`;
}

/**
 * A bucket record.
 *
 * `drawn:false` -> COUNTS ONLY, NEVER ENTRIES. K8-draft-2 §5.5's I3-02 row: "every bucket with
 * its counts (§5.6) and whether it is drawn; FOR EACH DRAWN BUCKET, one page of entries". A
 * non-drawn bucket therefore contributes counts and zero drawn content, and this module refuses
 * to read entries off one even if a (non-conforming) response carried them.
 */
function makeBucket({ participantKey, wireBucket, entryCount }) {
  const drawn = wireBucket.drawn === true;
  return Object.freeze({
    participantKey,
    linkType: wireBucket['link-type'] ?? null,
    narrowing: Object.freeze({
      kind: Object.freeze([...(wireBucket.narrowing?.kind ?? [])]),
      cardType: Object.freeze([...(wireBucket.narrowing?.['card-type'] ?? [])]),
      direction: Object.freeze([...(wireBucket.narrowing?.direction ?? [])]),
    }),
    counts: Object.freeze({
      neighbourCount: wireBucket.counts?.['neighbour-count'] ?? null,
      linkCount: wireBucket.counts?.['link-count'] ?? null,
      linkCopyCount: wireBucket.counts?.['link-copy-count'] ?? null,
      positionSubtotals: Object.freeze(
        (wireBucket.counts?.['position-subtotals'] ?? []).map((s) =>
          Object.freeze({ position: s.position, count: s.count }),
        ),
      ),
    }),
    drawn,
    // Counts-only when not drawn. This is the number of entries THIS GRAPH took from the
    // bucket, which is 0 for a non-drawn bucket by construction.
    ingestedEntryCount: drawn ? entryCount : 0,
    selfLinkCount: (wireBucket['self-links'] ?? []).length,
  });
}

// ------------------------------------------------------------------------- idempotent merges

/**
 * Merge an element. IDEMPOTENT ON (key, digest): re-ingesting the same page changes nothing.
 *
 * A DIFFERENT digest for the same key is a DIFFERENT state of that thing, so it is a distinct
 * record rather than an overwrite — K8-draft-2 §5.9 makes a label/class/trash/is-participant
 * change an ordinary change the client animates, and silently clobbering the old record would
 * destroy the before-state that animation needs. The focus flag is the one monotone field: a
 * thing seen as the focus participant stays flagged.
 */
function mergeElement(graph, element) {
  const id = identityOf(element);
  const existing = graph.elements.get(id);
  if (!existing) {
    graph.elements.set(id, element);
    return { added: true, changed: true };
  }
  if (element.isFocusParticipant && !existing.isFocusParticipant) {
    graph.elements.set(id, Object.freeze({ ...existing, isFocusParticipant: true }));
    return { added: false, changed: true };
  }
  return { added: false, changed: false };
}

/**
 * Merge a connection. IDEMPOTENT ON (key, digest).
 *
 * The things that accumulate are PARTICIPANTS, POSITIONS and SPOKES.
 *
 * WHY ACCUMULATION IS NECESSARY AND NOT A CONVENIENCE: a link of arity >= 3 is reported ONCE
 * PER NEIGHBOUR, and each report names only the subject's positions and THAT neighbour's
 * positions. The recorded 3-participant link `(introduces (Card 1) (Card 2) (Card 3))` appears
 * twice in one `open` response — as subject-positions [2] + neighbour-positions [1], and as
 * subject-positions [2] + neighbour-positions [3]. NO SINGLE REPORT SHOWS ARITY 3; only the
 * union of the two does. So `arity` and therefore the drawn form are recomputed from
 * `knownPositions`, the union across every report merged so far.
 *
 * This never INVENTS a position: the union only ever contains positions the store stated. A
 * link whose other participants were never reported keeps the lower arity it was told about,
 * which is the honest answer — and `is-participant` (a wire boolean) independently forces a
 * link node when the store says the link is itself a participant.
 *
 * Union is idempotent, so re-ingesting the same page still changes nothing.
 */
function mergeConnection(graph, connection) {
  const id = identityOf(connection);
  const existing = graph.connections.get(id);
  if (!existing) {
    graph.connections.set(id, connection);
    return { added: true, changed: true };
  }
  const byKey = new Map();
  for (const p of existing.participants) byKey.set(`${p.key}\u0000${p.role}`, p);
  let grew = false;
  for (const p of connection.participants) {
    const k = `${p.key}\u0000${p.role}`;
    const prior = byKey.get(k);
    if (!prior) {
      byKey.set(k, p);
      grew = true;
      continue;
    }
    const union = [...new Set([...prior.positions, ...p.positions])].sort((a, b) => a - b);
    if (union.length !== prior.positions.length) {
      byKey.set(k, Object.freeze({ ...prior, positions: Object.freeze(union) }));
      grew = true;
    }
  }

  const knownPositions = [
    ...new Set([...existing.knownPositions, ...connection.knownPositions]),
  ].sort((a, b) => a - b);
  const positionsGrew = knownPositions.length !== existing.knownPositions.length;
  if (!grew && !positionsGrew) return { added: false, changed: false };

  const participants = [...byKey.values()];
  // Recomputed from the ACCUMULATED positions, per the note above.
  const drawnForm = resolveConnectionForm(knownPositions, existing.isParticipant);
  const spokes =
    drawnForm === DRAWN_FORMS.linkNode ? [...new Set(participants.map((p) => p.key))] : [];
  graph.connections.set(
    id,
    Object.freeze({
      ...existing,
      participants: Object.freeze(participants),
      knownPositions: Object.freeze(knownPositions),
      arity: knownPositions.length,
      drawnForm,
      spokes: Object.freeze(spokes),
    }),
  );
  return { added: false, changed: true };
}

function mergeBucket(graph, id, bucket) {
  const existing = graph.buckets.get(id);
  if (!existing) {
    graph.buckets.set(id, bucket);
    return;
  }
  if (bucket.ingestedEntryCount > existing.ingestedEntryCount) {
    graph.buckets.set(id, bucket);
  }
}

// ------------------------------------------------------------- ingesting one list of entries

/**
 * Ingest one page of bucket entries (the shape is identical in I3-02's
 * `buckets[].entries[]` and I3-03's top-level `entries[]`).
 */
function ingestEntries({
  graph,
  entries,
  participantKey,
  labelBearingFromWire,
  where,
  stats,
}) {
  for (const wireEntry of entries) {
    const element = makeElement({
      wire: wireEntry,
      labelBearingFromWire,
      isFocusParticipant: false,
      where: `${where} entry`,
    });
    const r = mergeElement(graph, element);
    if (r.added) stats.elementsAdded += 1;

    for (const wireLink of wireEntry.links ?? []) {
      const connection = makeConnection({
        wire: wireLink,
        subjectKey: participantKey,
        neighbourKey: element.key,
        isSelfLink: false,
        where: `${where} link`,
      });
      const cr = mergeConnection(graph, connection);
      if (cr.added) stats.connectionsAdded += 1;
    }

    // `links-continue` is a CONTINUATION TOKEN, not drawn content: when non-null this entry's
    // joining links are TRUNCATED and more exist. It is recorded as an unfinished extent so a
    // caller can fetch the rest; nothing is invented to stand in for the missing links.
    if (wireEntry['links-continue'] !== null && wireEntry['links-continue'] !== undefined) {
      stats.linksContinue.push({ entryKey: element.key, cursor: wireEntry['links-continue'] });
    }
  }
}

/** Ingest a bucket's `self-links` — loops on the subject itself (§5.6 N03). */
function ingestSelfLinks({ graph, selfLinks, participantKey, where, stats }) {
  for (const wireLink of selfLinks) {
    const connection = makeConnection({
      wire: wireLink,
      subjectKey: participantKey,
      neighbourKey: null,
      isSelfLink: true,
      where: `${where} self-link`,
    });
    const r = mergeConnection(graph, connection);
    if (r.added) stats.connectionsAdded += 1;
  }
}

// ============================================================================================
// PUBLIC INGESTION — I3-02 `open`
// ============================================================================================

/**
 * Ingest an I3-02 `open` response into a NEW drawn graph.
 *
 * Returns {elements, connections, buckets, envelopeState, classification, stats} — arrays and
 * plain data, plus the live graph for further merging.
 *
 * A response that is not state-reporting contributes NO DRAWN CONTENT: zero elements, zero
 * connections, zero buckets. That covers `empty`, `unknown`, `excluded`, `not ready`,
 * `unavailable`, `reload`, an unrecognised outcome (a protocol violation), and a null body
 * (a refusal / 414 — for which no outcome is invented).
 *
 * @param {object|null} response  the response body exactly as received (null for a refusal)
 * @param {DrawnGraph} [into]     merge into this graph instead of a new one
 */
export function ingestOpen(response, into) {
  const graph = into ?? emptyDrawnGraph();
  const classification = classifyResponse(response);
  const stats = { elementsAdded: 0, connectionsAdded: 0, bucketsSeen: 0, linksContinue: [] };

  if (!classification.contributesDrawnContent) {
    const state = response === null || response === undefined ? null : envelopeState(response);
    graph.envelopeState = state;
    graph.ingestLog.push({ endpoint: 'I3-02', classification, stats });
    return { graph, classification, envelopeState: state, stats, ...views(graph) };
  }

  const state = envelopeState(response);
  graph.envelopeState = state;
  const labelBearingFromWire = state.labelBearingProperties ?? [];

  const wireParticipant = response.participant;
  const focus = makeElement({
    wire: wireParticipant,
    labelBearingFromWire,
    isFocusParticipant: true,
    where: 'I3-02 participant',
  });
  if (mergeElement(graph, focus).added) stats.elementsAdded += 1;

  for (const wireBucket of response.buckets ?? []) {
    stats.bucketsSeen += 1;
    const drawn = wireBucket.drawn === true;
    // A NON-DRAWN bucket contributes COUNTS ONLY — never entries. Entries are not read off it
    // even if present, because §5.5 only promises entries "for each DRAWN bucket".
    const entries = drawn ? wireBucket.entries ?? [] : [];
    if (drawn) {
      ingestEntries({
        graph,
        entries,
        participantKey: focus.key,
        labelBearingFromWire,
        where: `I3-02 bucket ${wireBucket['link-type']}`,
        stats,
      });
      ingestSelfLinks({
        graph,
        selfLinks: wireBucket['self-links'] ?? [],
        participantKey: focus.key,
        where: `I3-02 bucket ${wireBucket['link-type']}`,
        stats,
      });
    }
    mergeBucket(
      graph,
      bucketIdentity(focus.key, wireBucket),
      makeBucket({ participantKey: focus.key, wireBucket, entryCount: entries.length }),
    );
  }

  graph.ingestLog.push({ endpoint: 'I3-02', classification, stats });
  return { graph, classification, envelopeState: state, stats, ...views(graph) };
}

// ============================================================================================
// PUBLIC INGESTION — I3-03 `neighbours`, an ADDITIVE PAGE
// ============================================================================================

/**
 * Ingest an I3-03 `neighbours` page, merged ADDITIVELY into an existing drawn graph.
 *
 * `cursor-stale` is RESPECTED AND REPORTED, never ignored and never silently healed: a stale
 * cursor means the page may have skipped or repeated entries relative to the extent the caller
 * believed it held. The page's own entries are still real recorded state at the envelope's
 * position, so they are merged (idempotently), and `cursorStale: true` is surfaced on the
 * result so the caller — whose job the paging policy is — can decide to restart the bucket.
 * This module makes no paging decision.
 *
 * `omitted` (§5.8) is carried through: what was left out is NAMED by the store, and nothing is
 * invented to fill the gap.
 *
 * @param {object|null} response
 * @param {DrawnGraph} graph  the graph to merge into (required: a page is additive by nature)
 */
export function ingestNeighboursPage(response, graph) {
  if (!graph) {
    throw new TypeError('ingestNeighboursPage merges into an existing graph; pass one');
  }
  const classification = classifyResponse(response);
  const stats = { elementsAdded: 0, connectionsAdded: 0, bucketsSeen: 0, linksContinue: [] };

  if (!classification.contributesDrawnContent) {
    const state = response === null || response === undefined ? null : envelopeState(response);
    graph.envelopeState = state;
    graph.ingestLog.push({ endpoint: 'I3-03', classification, stats });
    return {
      graph,
      classification,
      envelopeState: state,
      stats,
      cursorStale: state ? state.cursorStale : null,
      ...views(graph),
    };
  }

  const state = envelopeState(response);
  graph.envelopeState = state;
  const labelBearingFromWire = state.labelBearingProperties ?? [];

  // I3-03's `participant` is an identity stub: key, digest, class, is-participant — and NO
  // label block (observed across all 20 recorded I3-03 pages). It is merged as an element so
  // the connections have an endpoint, with labelForm 'none'. Its label is not fabricated; a
  // caller that needs the focus label has it from the `open` that preceded the page.
  const wireParticipant = response.participant;
  const focus = makeElement({
    wire: wireParticipant,
    labelBearingFromWire,
    isFocusParticipant: true,
    where: 'I3-03 participant',
  });
  if (mergeElement(graph, focus).added) stats.elementsAdded += 1;

  ingestEntries({
    graph,
    entries: response.entries ?? [],
    participantKey: focus.key,
    labelBearingFromWire,
    where: 'I3-03 page',
    stats,
  });
  ingestSelfLinks({
    graph,
    selfLinks: response['self-links'] ?? [],
    participantKey: focus.key,
    where: 'I3-03 page',
    stats,
  });

  // I3-03 reports ONE bucket (`bucket`) with its `counts` beside it, rather than I3-02's list.
  // A paged bucket is a drawn bucket by definition — it was paged because it is drawn.
  if (response.bucket) {
    stats.bucketsSeen += 1;
    const synthetic = {
      'link-type': response.bucket['link-type'],
      narrowing: response.bucket.narrowing,
      counts: response.counts,
      'self-links': response['self-links'] ?? [],
      drawn: true,
    };
    mergeBucket(
      graph,
      bucketIdentity(focus.key, synthetic),
      makeBucket({
        participantKey: focus.key,
        wireBucket: synthetic,
        entryCount: (response.entries ?? []).length,
      }),
    );
  }

  graph.ingestLog.push({ endpoint: 'I3-03', classification, stats });
  return {
    graph,
    classification,
    envelopeState: state,
    stats,
    cursorStale: state.cursorStale,
    ...views(graph),
  };
}

// ============================================================================================
// VIEWS
// ============================================================================================

/** Stable, sorted plain-array views of the graph. Sorting makes equality checks deterministic. */
export function views(graph) {
  const elements = [...graph.elements.values()].sort((a, b) =>
    identityOf(a) < identityOf(b) ? -1 : identityOf(a) > identityOf(b) ? 1 : 0,
  );
  const connections = [...graph.connections.values()].sort((a, b) =>
    identityOf(a) < identityOf(b) ? -1 : identityOf(a) > identityOf(b) ? 1 : 0,
  );
  const buckets = [...graph.buckets.entries()]
    .sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0))
    .map(([, b]) => b);
  return { elements, connections, buckets };
}

/**
 * A structural fingerprint of the drawn graph, for proving merge idempotence. It includes the
 * position slot explicitly so that a position silently appearing would change the fingerprint.
 */
export function fingerprint(graph) {
  const { elements, connections, buckets } = views(graph);
  return JSON.stringify({
    elements: elements.map((e) => [
      e.key,
      e.digest,
      e.entryClass,
      e.trash,
      e.labelForm,
      e.labelFields.map((f) => [f.property, f.text]),
      e.declaredHead,
      e.drawnForm,
      e.isParticipant,
      e.position,
      e.isFocusParticipant,
    ]),
    connections: connections.map((c) => [
      c.key,
      c.digest,
      c.linkType,
      c.participants.map((p) => [p.key, p.role, [...p.positions]]),
      [...c.knownPositions],
      c.arity,
      c.copyCount,
      c.isParticipant,
      c.drawnForm,
      [...c.spokes].sort(),
      c.isSelfLink,
      c.position,
    ]),
    buckets: buckets.map((b) => [
      b.participantKey,
      b.linkType,
      b.drawn,
      b.ingestedEntryCount,
      b.counts.neighbourCount,
      b.counts.linkCount,
      b.counts.linkCopyCount,
    ]),
  });
}

/** Every element's and connection's position slot, for asserting ingestion assigned none. */
export function allPositionSlots(graph) {
  const { elements, connections } = views(graph);
  return [...elements.map((e) => e.position), ...connections.map((c) => c.position)];
}
