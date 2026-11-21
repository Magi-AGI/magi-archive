// Presentation registry for the AtomSpace Visualizer client — lane E1.
//
// ============================================================================================
// WHAT THIS FILE IS
// ============================================================================================
// The presentation registry of cp030 §7.1, POPULATED. Zero dependencies; no imports; runs
// unchanged under node and in a browser.
//
// cp030 §7.1 is NORMATIVE and says verbatim: "Entries ship for `Card`, the nine link types and
// the eight properties of `cp022` §4. A head with no entry falls back to the generic form."
// Shipping entries is therefore REQUIRED. This file ships all nineteen declared heads of
// cp022 §4 (two constructors, eight properties, nine link types) plus the normative fallback.
//
// WHY THE NAMES ARE SETTLED (this file previously refused to ship entries, citing unadopted
// values; that refusal was over-broad and is corrected here):
//   - cp022 §4.1/§4.2/§4.3 declare the nineteen heads. cp022 §7's open points P1 (naming
//     style) and P5 (the head names) are SETTLED for this baseline: Lake approved the
//     nineteen declarations and the kebab-case/PascalCase style.
//   - The registry is keyed by DECLARED HEAD, exactly those strings (cp030 §7.1, K10 §3.1).
//   - DISPLAY LABELS are DERIVED from the settled heads by the documented transform in
//     deriveDisplayLabel() below — a de-kebab, not an invented vocabulary. That satisfies
//     R17's "a plain-word name shown in a legend and on hover, so a Viewer need not read head
//     symbols" without coining words nobody approved. The labels live in ONE place
//     (DISPLAY_LABELS, built by that transform), as K10 §3.4 requires.
//
// WHAT IS GROUNDED AND WHAT IS DEMO-LEVEL — the honest split, per value class:
//   GROUNDED (traceable to a cited sentence):
//     - the nineteen keys                 cp022 §4.1, §4.2, §4.3
//     - every display label               a documented transform of the settled head
//     - `Card`'s label order              cp030 §7.2: "a card by name and type name (R17)"
//     - name / type-name -> label         cp030 §7.2, same sentence
//     - trash -> visual state             cp030 §7.2 row: "a trashed card | an element in a
//                                         distinct style" — a style, not a form
//     - line-vs-link-node                 cp030 §7.2, COMPUTED from arity and is-participant;
//                                         no entry may override it (see DRAWN_FORM_IS_COMPUTED)
//     - structural vs reference split     cp022's own §4.2 / §4.3 division
//   DEMO-LEVEL (a concrete proposal, built to be looked at and changed):
//     - every shape, colour, line style and arrow token in VISUAL_TOKENS
// cp030 §7.7 makes visual acceptance "Lake's judgement on the running build" and commits to
// "one consistent visual language for link types and directions". Lake's instruction is "we'll
// know it when we see it": build the initial version, show it, expect to adjust. So the demo
// values are BUILT and SHOWN, marked as demo-level, and kept in ONE object so a change is one
// edit in one place.
//
// ============================================================================================
// WHAT THIS FILE STILL DOES NOT DECIDE — reserved to Lake, untouched here
// ============================================================================================
// No drawing budget of any kind (no element cap, no connection cap, no culling threshold).
// No refresh/liveness interval. No 2D-vs-3D commitment. No coordinate, camera, extent or
// geometry maths of any kind — this file holds no position data. Not D42 (GPU compute-shader
// layout). Not the S-legibility thresholds.
//
// K10 §3.4 / K8-draft-2 D2-4: the label-bearing property SET lives ON THE WIRE at
// `limits.label-bearing-properties` and the registry keeps NO COPY. This file stores no such
// set and derives nothing from one; an entry supplies only the ORDER, and
// orderPropertyLabelFields() THROWS if the caller does not hand it the wire set.
//
// V07 / V09: provenance is OMITTED on every view path. This file has no provenance concept and
// no path that could surface one. (`provenanceOfValues` on an entry is a developer note about
// where a presentation VALUE came from; it is not the view's provenance concept, is never a
// label, and is never rendered.)
//
// Text handling: every label field this module returns is a PLAIN STRING carrying text from
// the space AS DATA. Nothing here escapes, wraps, interpolates or emits markup, and no caller
// may treat these strings as markup (V07 / V09-family).
//
// Coded against cp022 §4 + cp030 §7 + K10 §3 (K8-draft-2 + addendum-1 remain WORKING DRAFT 2,
// NOT FROZEN). Re-point this file on any announced change.

const hasOwn = (o, k) => Object.prototype.hasOwnProperty.call(o, k);

// ------------------------------------------------------------- the nineteen declared heads

/**
 * The two CONSTRUCTORS of cp022 §4.1: `(: Card (-> Number Entity))` and
 * `(: Wanted (-> String Unresolved))`. PascalCase per cp022 §2's Best-Practices rule
 * (types in PascalCase), settled with P1.
 *
 * @type {ReadonlyArray<string>}
 */
export const CONSTRUCTOR_HEADS = Object.freeze(['Card', 'Wanted']);

/**
 * The eight PROPERTIES of cp022 §4.1, in that section's table order.
 *
 * @type {ReadonlyArray<string>}
 */
export const PROPERTY_HEADS = Object.freeze([
  'name',
  'key',
  'codename',
  'type-name',
  'content',
  'trash',
  'created-at',
  'updated-at',
]);

/**
 * The nine LINK TYPES, in cp022 order: the five STRUCTURAL links of §4.2 then the four
 * REFERENCE links of §4.3. The split is the data model's own and is what the two line styles
 * in VISUAL_TOKENS express (cp030 §7.7's "one consistent visual language").
 *
 * @type {ReadonlyArray<string>}
 */
export const LINK_TYPES = Object.freeze([
  // cp022 §4.2 — structural
  'has-type',
  'left-part',
  'right-part',
  'created-by',
  'updated-by',
  // cp022 §4.3 — reference
  'includes',
  'links-to',
  'queries',
  'partial-ref',
]);

const STRUCTURAL_LINKS = Object.freeze(LINK_TYPES.slice(0, 5));
const REFERENCE_LINKS = Object.freeze(LINK_TYPES.slice(5));

/** Predicate: is this head one of the nine declared link types? */
export function isLinkHead(head) {
  return typeof head === 'string' && LINK_TYPES.includes(head);
}

/** Predicate: is this head one of the eight declared properties? */
export function isPropertyHead(head) {
  return typeof head === 'string' && PROPERTY_HEADS.includes(head);
}

/** Predicate: is this head one of the two declared constructors? */
export function isConstructorHead(head) {
  return typeof head === 'string' && CONSTRUCTOR_HEADS.includes(head);
}

// ------------------------------------------------------------------ display labels, DERIVED

/**
 * The ONE exception to the de-kebab transform, and it is not an invention either: cp022 §4.3
 * names this link "partial reference" outright in its own table ("`partial-ref` | `P` | partial
 * reference: generated for the parts of a compound name..."). The source's word wins over the
 * transform.
 */
const DISPLAY_LABEL_EXCEPTIONS = Object.freeze({
  'partial-ref': 'partial reference',
});

/**
 * DERIVE a display label from a SETTLED declared head. This is the transform, written once so
 * the rule is visible in the code rather than hidden in nineteen hand-typed strings:
 *
 *   1. a head cp022 names in prose wins (DISPLAY_LABEL_EXCEPTIONS: `partial-ref`)
 *   2. otherwise: replace each hyphen with a space, and change NOTHING else.
 *
 * So `has-type` -> "has type", `links-to` -> "links to", `created-by` -> "created by",
 * `type-name` -> "type name", `created-at` -> "created at"; and a head with no hyphen is its
 * own label (`name` -> "name", `includes` -> "includes", `Card` -> "Card").
 *
 * CASE IS NOT TOUCHED, deliberately. The two constructors are declared PascalCase and that IS
 * the settled name, so they come through as "Card" and "Wanted". Lower-casing them to
 * "card"/"wanted" (as k10-client-protocol-v0 §12 C4 once proposed) would be a second,
 * undocumented decision about presentation case; it is exactly the kind of adjustment Lake
 * makes on the running build, and it is a one-line change here if he wants it.
 *
 * @param {string} head a settled declared head
 * @returns {string} the plain-word display label (R17)
 */
export function deriveDisplayLabel(head) {
  if (typeof head !== 'string') {
    throw new TypeError('deriveDisplayLabel expects a declared head string');
  }
  if (hasOwn(DISPLAY_LABEL_EXCEPTIONS, head)) return DISPLAY_LABEL_EXCEPTIONS[head];
  return head.split('-').join(' ');
}

const DISPLAY_LABEL_DERIVATION =
  'displayLabel DERIVED from the settled declared head by deriveDisplayLabel(): de-kebab ' +
  '(hyphen -> space), case untouched; sole exception `partial-ref` -> "partial reference", ' +
  'which cp022 §4.3 names in prose. No vocabulary is invented (R17).';

const ALL_HEADS = Object.freeze([...CONSTRUCTOR_HEADS, ...PROPERTY_HEADS, ...LINK_TYPES]);

/**
 * The head -> DISPLAY LABEL mapping. K10 §3.4: "It is held ONCE, in the head's registry entry,
 * and every surface reads it from there... No second table, no duplicate string, no label
 * derived by transforming a head's text at a call site."
 *
 * This object IS that one place. The transform runs HERE, once, at module load; call sites read
 * the result and never re-derive. Changing a label is a one-line data edit in this file (an
 * exception entry, or the transform itself) and every surface follows.
 *
 * @type {Readonly<Record<string, string>>}
 */
export const DISPLAY_LABELS = Object.freeze(
  ALL_HEADS.reduce((acc, head) => {
    acc[head] = deriveDisplayLabel(head);
    return acc;
  }, {}),
);

// --------------------------------------------------------------- the drawn forms, and who owns them

/**
 * The drawn FORMS of cp030 §7.2. These six strings are this client's own vocabulary for the
 * forms that section enumerates; they are not wire values and the store never sends them.
 *
 * FROZEN SHAPE: another module re-exports this object. Do not add, remove or rename a pair.
 */
export const DRAWN_FORMS = Object.freeze({
  element: 'element', // an entity (a card: by name and type-name, R17)
  line: 'line', // a link with exactly two participants, directed
  linkNode: 'link-node', // >=3 participants, OR a link that is itself a participant
  stub: 'stub', // an unresolved reference, from its source
  placeholder: 'placeholder', // a card referenced but not in the space; a missing participant
  generic: 'generic', // undeclared kind / bare symbol / grounded value / empty expression
});

/**
 * The value every entry's `drawnAs` carries, and the reason it is a sentinel rather than a
 * form.
 *
 * Line-vs-link-node is NOT a per-entry choice. cp030 §7.2 DERIVES it: a link with exactly two
 * participants is a line; a link with three or more participants, OR a link that is itself a
 * participant in another link, is a link node. Arity and `is-participant` come off the wire per
 * atom, so the SAME link type is a line in one place and a link node in another. An entry that
 * hardcoded 'line' would be wrong for half the corpus.
 *
 * So the registry records WHO DECIDES, not the decision. drawn-graph.mjs computes the form from
 * arity and is-participant and must never consult this field as an override.
 */
export const DRAWN_FORM_IS_COMPUTED = 'computed-per-cp030-7.2';

// ------------------------------------------------------------- DEMO-LEVEL visual vocabulary

/**
 * ########################################################################################
 * # EVERY VALUE IN THIS OBJECT IS A DEMO-LEVEL PRESENTATION PROPOSAL.                     #
 * #                                                                                       #
 * # cp030 §7.7 makes visual acceptance "Lake's judgement on the running build". Lake's     #
 * # instruction is "we'll know it when we see it": these are concrete, buildable, shown-   #
 * # to-him values, NOT adopted ones. Expect to change them.                               #
 * #                                                                                       #
 * # They are all HERE, in this one frozen object, so that adjusting the visual language is #
 * # one edit in one place and no shape, colour, line style or arrow is scattered through   #
 * # the renderer. Entries below reference these tokens by name; they never inline a value. #
 * ########################################################################################
 *
 * The ONE structural claim these tokens encode is grounded: structural links (cp022 §4.2) and
 * reference links (cp022 §4.3) get DIFFERENT line styles, so the distinction a Viewer sees is
 * the data model's own division rather than a decorative choice (cp030 §7.7's "one consistent
 * visual language for link types and directions"). WHICH styles is demo-level; THAT they differ
 * is not.
 *
 * No value here is a budget, a threshold, an interval, a dimension count or a coordinate.
 */
export const VISUAL_TOKENS = Object.freeze({
  status: 'DEMO-LEVEL PROPOSAL — cp030 §7.7, Lake adjusts on the running build',

  /** Element shapes, for cp030 §7.1's "the element's shape". */
  shapes: Object.freeze({
    cardElement: 'rounded-rect',
    wantedStub: 'dashed-pill',
    placeholderElement: 'dotted-rect',
    genericElement: 'hexagon',
    linkNode: 'small-diamond',
  }),

  /** Line styles. The structural/reference pair is the grounded distinction. */
  lineStyles: Object.freeze({
    structural: 'solid',
    reference: 'dashed',
    spoke: 'hairline', // link node to each participant (cp030 §7.2)
  }),

  /** Arrowhead treatments. Every declared link of cp022 §4 is directed, source first. */
  arrows: Object.freeze({
    directedForward: 'arrowhead-at-target',
    none: 'none',
  }),

  /**
   * Colours, as a palette keyed by ROLE rather than by individual head, so nine link types do
   * not become nine unrelated hues. Demo-level like everything else here.
   */
  colours: Object.freeze({
    structural: '#4c6ef5',
    reference: '#12b886',
    element: '#495057',
    placeholder: '#adb5bd',
    unresolved: '#f08c00',
    generic: '#868e96',
  }),

  /**
   * Visual STATES — cp030 §7.1's third entry row ("whether it appears in the label, as a
   * visual state, or only in the inspector") and §7.2's "a trashed card | an element in a
   * distinct style". A state is a STYLE applied to an element, never a different drawn form.
   */
  states: Object.freeze({
    trashed: 'dimmed-with-strikethrough-label',
  }),
});

// ---------------------------------------------------------------- property placement (cp030 §7.1)

/**
 * Where each of the eight properties appears: in the LABEL, as a VISUAL STATE, or only in the
 * INSPECTOR. This is cp030 §7.1's third entry row, which is exactly a three-way placement.
 *
 * GROUNDED:
 *   - `name`, `type-name` -> 'label'. cp030 §7.2: "an element, labelled per its entry; a card
 *     by name and type name (R17)".
 *   - `trash` -> 'visual-state'. cp030 §7.2 gives a trashed card its own row and asks for "an
 *     element in a distinct style" — a style, not a form and not a label field.
 *   - the remaining five (`key`, `codename`, `content`, `created-at`, `updated-at`) have NO
 *     stated presentation role anywhere in cp022 or cp030, so they are INSPECTOR-only. That is
 *     the conservative reading: a property nobody asked to see on the element is not put on it.
 *
 * CORROBORATION, not the source of this: `limits.label-bearing-properties` is observed on the
 * wire as name / type-name / trash, which is precisely the three non-inspector placements
 * above. The agreement is a useful check that this placement table is not at odds with the
 * store. It is NOT where the table comes from, and this module stores no copy of that wire set
 * (K10 §3.4) — the eight keys below are the eight DECLARED PROPERTIES of cp022 §4.1, a
 * different thing from the store's three-member label-bearing set.
 *
 * @type {Readonly<Record<string, 'label'|'visual-state'|'inspector'>>}
 */
export const PROPERTY_PLACEMENTS = Object.freeze({
  name: 'label',
  key: 'inspector',
  codename: 'inspector',
  'type-name': 'label',
  content: 'inspector',
  trash: 'visual-state',
  'created-at': 'inspector',
  'updated-at': 'inspector',
});

// ---------------------------------------------------------------- label ORDER, and only order

/**
 * K10 §3.4: the label-bearing property SET lives ON THE WIRE and the registry keeps NO COPY —
 * a registry entry supplies only the ORDER.
 *
 * This module therefore holds NO set of label-bearing properties. The set must be read from
 * the response envelope's `limits.label-bearing-properties` and from NOWHERE ELSE. The observed
 * value in the lane-F recordings is name / type-name / trash, but that is an OBSERVATION of one
 * recorded revision, not a constant, and nothing here caches it.
 */

/**
 * The label ORDER for a property-derived (entity) label, used by `Card` and by the generic
 * fallback.
 *
 * GROUNDED, NOT INVENTED: cp030 §7.2's entity row reads "an element, labelled per its entry; a
 * card by name and type name (R17)". The order name-then-type-name is that sentence's order.
 */
export const GENERIC_PROPERTY_LABEL_ORDER = Object.freeze(['name', 'type-name']);

/**
 * The GENERIC FALLBACK's label ORDER for a STRUCTURAL label.
 *
 * GROUNDED, NOT INVENTED: cp030 §7.2's generic row reads "a generic element, labelled by head
 * and a shortened form of its parts". The order head-then-parts is that sentence's order.
 *
 * NOTE on scope, so this is not over-read: `head` and `parts` are NOT properties of a card and
 * are NOT members of `limits.label-bearing-properties`. The structural {head, parts} label
 * block is supplied directly by the store for non-entity classes and is not property-derived,
 * so the wire SET does not gate it. SHORTENING the parts is a presentation choice with no
 * adopted rule; this module performs none and passes recorded text through verbatim as data.
 */
export const GENERIC_STRUCTURAL_LABEL_ORDER = Object.freeze(['head', 'parts']);

// ------------------------------------------------------------------------- the entry shape

/**
 * @typedef {object} RegistryEntry
 * @property {string|null} head            the declared head this entry is keyed by
 * @property {'constructor'|'link'|'property'|null} kind  which cp030 §7.1 row applies
 * @property {string|null} displayLabel    plain-word legend/hover name (R17)
 * @property {string|null} shape           element shape token (constructors only)
 * @property {string|null} lineStyle       link line style token (links only)
 * @property {string|null} arrow           link arrowhead token (links only)
 * @property {string|null} drawnAs         always DRAWN_FORM_IS_COMPUTED for a drawn kind
 * @property {'structural'|'reference'|null} group  cp022 §4.2 vs §4.3 (links only)
 * @property {'label'|'visual-state'|'inspector'|null} placement  (properties only)
 * @property {ReadonlyArray<string>|null} propertyLabelOrder  the ORDER only (K10 §3.4)
 * @property {boolean} isFallback          true when produced by the generic fallback
 * @property {string} provenanceOfValues   what is grounded here and what is demo-level
 *
 * EVERY entry carries EVERY key, using null where the key does not apply, so a caller reading
 * entry.shape / entry.lineStyle / entry.arrow / entry.displayLabel / entry.propertyLabelOrder
 * never sees undefined.
 */

const ENTRY_KEYS = Object.freeze([
  'head',
  'kind',
  'displayLabel',
  'shape',
  'lineStyle',
  'arrow',
  'drawnAs',
  'group',
  'placement',
  'propertyLabelOrder',
  'isFallback',
  'provenanceOfValues',
]);

/** Build a complete, frozen entry: every documented key present, nulls where inapplicable. */
function makeEntry(fields) {
  return Object.freeze({
    head: null,
    kind: null,
    displayLabel: null,
    shape: null,
    lineStyle: null,
    arrow: null,
    drawnAs: null,
    group: null,
    placement: null,
    propertyLabelOrder: null,
    isFallback: false,
    provenanceOfValues: '',
    ...fields,
  });
}

/** The documented key set of an entry, exported for tests and for the inspector. */
export const REGISTRY_ENTRY_KEYS = ENTRY_KEYS;

// --------------------------------------------------------------------------- the entries

const CARD_ENTRY_NOTE =
  'GROUNDED: key is the declared constructor of cp022 §4.1; propertyLabelOrder ' +
  '["name","type-name"] is cp030 §7.2 verbatim ("a card by name and type name (R17)"); ' +
  'drawnAs is computed per cp030 §7.2, never fixed here. ' +
  DISPLAY_LABEL_DERIVATION +
  ' DEMO-LEVEL: the shape token (VISUAL_TOKENS.shapes), adjustable per cp030 §7.7.';

const WANTED_ENTRY_NOTE =
  'GROUNDED: key is the declared constructor of cp022 §4.1; cp030 §7.2 draws an unresolved ' +
  'reference as "a stub from its source, labelled with the wanted key", so no ' +
  'property-derived label order applies and propertyLabelOrder is null; drawnAs is computed ' +
  'per cp030 §7.2. ' +
  DISPLAY_LABEL_DERIVATION +
  ' DEMO-LEVEL: the shape token (VISUAL_TOKENS.shapes), adjustable per cp030 §7.7.';

const LINK_ENTRY_NOTE_GROUNDED =
  'GROUNDED: key is a declared link type of cp022 §4; its group is cp022\u2019s own section ' +
  'split (§4.2 structural / §4.3 reference), which is what the two line styles express ' +
  '(cp030 §7.7, "one consistent visual language"); drawnAs is COMPUTED per cp030 §7.2 from ' +
  'arity and is-participant and this entry must never override it. ' +
  DISPLAY_LABEL_DERIVATION;

const LINK_ENTRY_NOTE_DEMO =
  ' DEMO-LEVEL: the lineStyle and arrow tokens (VISUAL_TOKENS), adjustable per cp030 §7.7.';

const PROPERTY_PLACEMENT_NOTE = Object.freeze({
  label:
    'GROUNDED: key is a declared property of cp022 §4.1; placement "label" is cp030 §7.2 ' +
    '("a card by name and type name (R17)"). Corroborated by the wire\u2019s ' +
    'label-bearing set, of which this module keeps no copy (K10 §3.4). ' +
    DISPLAY_LABEL_DERIVATION +
    ' DEMO-LEVEL: nothing — this entry carries no visual token.',
  'visual-state':
    'GROUNDED: key is a declared property of cp022 §4.1; placement "visual-state" is cp030 ' +
    '§7.2\u2019s own row "a trashed card | an element in a distinct style" — a STYLE, not a ' +
    'drawn form and not a label field. Corroborated by the wire\u2019s label-bearing set, of ' +
    'which this module keeps no copy (K10 §3.4). ' +
    DISPLAY_LABEL_DERIVATION +
    ' DEMO-LEVEL: the state token VISUAL_TOKENS.states.trashed, adjustable per cp030 §7.7.',
  inspector:
    'GROUNDED: key is a declared property of cp022 §4.1; placement "inspector" because NO ' +
    'source gives this property a label or visual-state role, and a property nobody asked to ' +
    'see on the element is not put on it. Corroborated by its absence from the wire\u2019s ' +
    'label-bearing set, of which this module keeps no copy (K10 §3.4). ' +
    DISPLAY_LABEL_DERIVATION +
    ' DEMO-LEVEL: nothing — this entry carries no visual token.',
});

function constructorEntry(head, shapeToken, propertyLabelOrder, note) {
  return makeEntry({
    head,
    kind: 'constructor',
    displayLabel: DISPLAY_LABELS[head],
    shape: shapeToken,
    drawnAs: DRAWN_FORM_IS_COMPUTED,
    propertyLabelOrder,
    provenanceOfValues: note,
  });
}

function linkEntry(head, group) {
  return makeEntry({
    head,
    kind: 'link',
    displayLabel: DISPLAY_LABELS[head],
    lineStyle:
      group === 'structural'
        ? VISUAL_TOKENS.lineStyles.structural
        : VISUAL_TOKENS.lineStyles.reference,
    arrow: VISUAL_TOKENS.arrows.directedForward,
    drawnAs: DRAWN_FORM_IS_COMPUTED,
    group,
    provenanceOfValues: LINK_ENTRY_NOTE_GROUNDED + LINK_ENTRY_NOTE_DEMO,
  });
}

function propertyEntry(head) {
  const placement = PROPERTY_PLACEMENTS[head];
  return makeEntry({
    head,
    kind: 'property',
    displayLabel: DISPLAY_LABELS[head],
    // A property is not itself a drawn element or connection; it contributes to another
    // kind's label, style or inspector. So no form is computed for it.
    drawnAs: null,
    placement,
    provenanceOfValues: PROPERTY_PLACEMENT_NOTE[placement],
  });
}

/**
 * The registry, keyed BY DECLARED HEAD, exactly as cp030 §7.1 requires ("How a kind of atom is
 * drawn is an entry in a presentation registry, keyed by declared head"). The key is the head
 * symbol's own text as declared in a `(: h ...)` atom (cp022 §3.1, K10 §3.1) — not a display
 * label, not a Decko reference code, not a position in a list.
 *
 * Nineteen entries: 2 constructors + 8 properties + 9 link types (cp022 §4).
 *
 * @type {Readonly<Record<string, RegistryEntry>>}
 */
export const REGISTRY_ENTRIES = Object.freeze({
  // --- cp022 §4.1, the two constructors ---
  Card: constructorEntry(
    'Card',
    VISUAL_TOKENS.shapes.cardElement,
    GENERIC_PROPERTY_LABEL_ORDER,
    CARD_ENTRY_NOTE,
  ),
  Wanted: constructorEntry('Wanted', VISUAL_TOKENS.shapes.wantedStub, null, WANTED_ENTRY_NOTE),

  // --- cp022 §4.1, the eight properties ---
  ...PROPERTY_HEADS.reduce((acc, head) => {
    acc[head] = propertyEntry(head);
    return acc;
  }, {}),

  // --- cp022 §4.2, the five structural links ---
  ...STRUCTURAL_LINKS.reduce((acc, head) => {
    acc[head] = linkEntry(head, 'structural');
    return acc;
  }, {}),

  // --- cp022 §4.3, the four reference links ---
  ...REFERENCE_LINKS.reduce((acc, head) => {
    acc[head] = linkEntry(head, 'reference');
    return acc;
  }, {}),
});

// ------------------------------------------------------------------- the normative fallback

const GENERIC_VALUE_NOTE =
  'generic fallback: this head has NO registry entry, so no presentation value is adopted or ' +
  'derivable for it and every value slot is null rather than guessed. cp030 §7.1: "A head ' +
  'with no entry falls back to the generic form." A display label is NOT synthesised from head ' +
  'text — cp030 §7.2\u2019s "undeclared link types show their head text" is a statement about ' +
  'what the VIEW shows, not a licence to mint a registry display label.';

/**
 * The NORMATIVE generic fallback. cp030 §7.1: "A head with no entry falls back to the generic
 * form." That clause stays live now that entries exist: undeclared heads, conflicted heads,
 * bare symbols, grounded values, empty expressions and the null head an entity-form label
 * yields all land here.
 *
 * @param {string|null} head
 * @returns {RegistryEntry}
 */
export function genericFallbackEntry(head) {
  return makeEntry({
    head: head === null || head === undefined ? null : String(head),
    kind: null,
    displayLabel: null,
    shape: null,
    lineStyle: null,
    arrow: null,
    drawnAs: null,
    group: null,
    placement: null,
    propertyLabelOrder: GENERIC_PROPERTY_LABEL_ORDER,
    isFallback: true,
    provenanceOfValues: GENERIC_VALUE_NOTE,
  });
}

/**
 * Look an entry up by DECLARED HEAD. One of the nineteen returns its real entry
 * (isFallback false); anything else — including `null`, the head an entity-class element's
 * property-form label yields (see drawn-graph.mjs on why that is not a wire field) — takes the
 * normative generic fallback (isFallback true).
 *
 * @param {string|null} head
 * @returns {RegistryEntry}
 */
export function lookupByDeclaredHead(head) {
  if (typeof head === 'string' && hasOwn(REGISTRY_ENTRIES, head)) {
    return REGISTRY_ENTRIES[head];
  }
  return genericFallbackEntry(head ?? null);
}

/**
 * The display label for a head, or null when the head has no entry.
 *
 * NEVER falls back to head text. Synthesising a display label for a head with no entry would
 * mint registry data at a call site, which K10 §3.4 forbids ("no label derived by transforming
 * a head's text at a call site"). The derivation in deriveDisplayLabel() applies ONLY to the
 * nineteen SETTLED declared heads, and it has already been applied, once, into DISPLAY_LABELS.
 *
 * @param {string|null} head
 * @returns {string|null}
 */
export function displayLabelFor(head) {
  if (typeof head === 'string' && hasOwn(DISPLAY_LABELS, head)) {
    return DISPLAY_LABELS[head];
  }
  return null;
}

/**
 * True when the registry holds no entries at all. It now ships nineteen (cp030 §7.1: "Entries
 * ship for `Card`, the nine link types and the eight properties of `cp022` §4"), so this
 * returns FALSE. Kept because callers use it to decide whether every head will take the
 * fallback.
 */
export function registryIsEmpty() {
  return Object.keys(REGISTRY_ENTRIES).length === 0;
}

/**
 * The LEGEND rows (R17: "Every link type has a plain-word name shown in a legend and on hover,
 * so a Viewer need not read head symbols"). Ordered as cp022 orders them: the five structural
 * links of §4.2, then the four reference links of §4.3, so the legend itself shows the data
 * model's division.
 *
 * Returns plain strings only. No coordinate, no size, no swatch geometry — a legend's layout is
 * the view's business, not the registry's.
 *
 * @returns {Array<{head: string, displayLabel: string, lineStyle: string, arrow: string, group: 'structural'|'reference'}>}
 */
export function legendRows() {
  return LINK_TYPES.map((head) => {
    const entry = REGISTRY_ENTRIES[head];
    return Object.freeze({
      head: entry.head,
      displayLabel: entry.displayLabel,
      lineStyle: entry.lineStyle,
      arrow: entry.arrow,
      group: entry.group,
    });
  });
}

// ------------------------------------------------------------------------- label field ordering

/**
 * Order a PROPERTY-DERIVED label block.
 *
 * The SET comes from the caller, which must have read it off the response envelope's
 * `limits.label-bearing-properties` (K10 §3.4) — this module keeps no copy and accepts no
 * default. The ORDER comes from the registry entry.
 *
 * Returns ordered {property, text} pairs. `text` is a PLAIN STRING, text as data, never markup.
 * A property in the order but absent from the label block, or absent from the wire SET, yields
 * no field — nothing is invented to fill a slot.
 *
 * @param {Record<string, unknown>} labelBlock       the wire `label` block
 * @param {ReadonlyArray<string>} labelBearingFromWire  limits.label-bearing-properties
 * @param {ReadonlyArray<string>} order              the registry-supplied order
 * @returns {Array<{property: string, text: string}>}
 */
export function orderPropertyLabelFields(labelBlock, labelBearingFromWire, order) {
  if (!labelBlock || typeof labelBlock !== 'object') return [];
  if (!Array.isArray(labelBearingFromWire)) {
    throw new TypeError(
      'label-bearing property set must be supplied from the response envelope ' +
        '(limits.label-bearing-properties); this registry keeps no copy (K10 §3.4)',
    );
  }
  const onWire = new Set(labelBearingFromWire);
  const fields = [];
  for (const property of order) {
    if (!onWire.has(property)) continue;
    if (!hasOwn(labelBlock, property)) continue;
    const raw = labelBlock[property];
    if (typeof raw !== 'string') continue;
    fields.push(Object.freeze({ property, text: raw }));
  }
  return fields;
}

/**
 * Order a STRUCTURAL ({head, parts}) label block. Not property-derived, so the wire's
 * label-bearing property set does not gate it (see GENERIC_STRUCTURAL_LABEL_ORDER's note).
 * Text passes through verbatim as data; no shortening is applied, because no shortening rule
 * is adopted.
 *
 * @param {Record<string, unknown>} labelBlock
 * @param {ReadonlyArray<string>} order
 * @returns {Array<{property: string, text: string}>}
 */
export function orderStructuralLabelFields(labelBlock, order) {
  if (!labelBlock || typeof labelBlock !== 'object') return [];
  const fields = [];
  for (const property of order) {
    if (!hasOwn(labelBlock, property)) continue;
    const raw = labelBlock[property];
    if (typeof raw !== 'string') continue;
    fields.push(Object.freeze({ property, text: raw }));
  }
  return fields;
}
