// ================================================================================================
// LIVE I3 TRANSPORT BRIDGE  —  src/demo/live-bridge.mjs
// ================================================================================================
//
// WHAT THIS IS.  The live sibling of fixture-bridge.mjs.  It speaks the I3 VIEW surface
// (`lookup` -> `open` -> `neighbours`) over HTTP GET and hands the WIRE BODY, unaltered, to the
// SAME ingestion entrypoints the fixture path uses (`ingestOpen` / `ingestNeighboursPage` from
// ../drawn-graph.mjs).  It therefore produces the SAME scene shape, and the renderer and the
// layout are untouched and unaware of which transport produced a scene.  No renderer or layout
// input shape was changed, widened or reinterpreted for this transport's convenience.
//
// WHAT I3 IS.  I3 is the NON-PRIVILEGED read surface.  It is NOT I2.  I2 is privileged,
// identity-free, not exposed on any socket, and exposing it publicly is PROHIBITED
// (av-view/experiments/lane-d-adapter/i2_binding.py:16-17, :33-34 quoting
// av-store-sidecar/atomspace_mirror_sidecar/i2_read.py:57-58).  This module therefore never
// names, reaches for, or emulates an I2 operation.  It makes exactly the three I3 requests.
//
// REQUEST/RESPONSE SEAM.  Every path, parameter name, encoding rule and response field below is
// taken from VIEW's own source, not from a summary:
//   * paths and query-parameter names .. av-view/experiments/lane-d-adapter/routes.py:30, :98,
//        :143-150, :160-167, :245-247 (ROUTE_PREFIX = "/atomspace/api/")
//   * "All inputs are query parameters. No endpoint accepts a body." .. routes.py:6 quoting
//        cpd001 §1 / K8 §5.1 L288
//   * percent-encoding is the TRANSPORT's job, done exactly once .. adapter.py:3-5, routes.py:246
//   * the three-call path, its gate and its bucket choice .. i2_binding.py:480-549
//        (`real_card_path`), mirrored exactly by `realCardPath` below
//   * the nine outcomes, closed set .. adapter.py:36-51
//   * the envelope's six fields, and `health` only on degraded / not ready .. adapter.py:755-767
//   * the all-null state triple is legal on `not ready` and `unavailable` ONLY ..
//        adapter.py:53-55, :810-812; record_store.py:196-201
//
// `real_card_path` DOES NOT BUILD A URL.  Despite the name it performs no path construction and
// no escaping: "path" there means the SEQUENCE of three I3 calls (i2_binding.py:457-492).  The
// percent-encoding it omits is this module's job, and `encodeI3Query` below is that job, done
// exactly once.  `realCardPath` here is the same sequence with the same gate, the same
// kind-preserving address and the same bucket rule.
//
// NO MANUFACTURED STATE.  This module never invents an outcome, an epoch, a position, a read-at,
// a digest, a limit or a health slice.  In particular it does NOT synthesise the `unavailable`
// envelope that VIEW's in-process adapter synthesises on a StoreUnavailable (adapter.py:770-803):
// doing so in the client would be fabricating a store answer out of a browser-side network
// error.  A transport failure THROWS a typed error carrying the real status and the real reason.
// A refusal body of `null` is passed through as `null`, for which drawn-graph.mjs invents no
// outcome by design.
//
// NO SILENT FALLBACK.  There is no fixture path in this module, no recorded corpus, no cache and
// no default backend origin.  Every absence raises a typed error naming exactly what is missing.
// `MODE` is the single literal 'live-http-i3' and nothing here can produce any other value, so a
// fixture response can never be labelled as live.
//
// NO BEARER CREDENTIALS IN THE BROWSER.  This module has no token parameter, no Authorization
// header and no auth configuration of any kind, in EITHER credential branch.  What it does have
// is TWO EXPLICIT branches, selected by `credentialMode` and never guessed:
//
//   * `none` (DEFAULT) — `credentials: 'omit'`.  No cookie, no HTTP-auth state, any origin the
//     loopback rule permits.  This is the only branch allowed cross-origin.
//   * `decko-session` — `credentials: 'same-origin'`, reusing a Decko session cookie the user's
//     browser ALREADY HOLDS, and ONLY for an explicitly selected SAME-ORIGIN backend.  Every
//     request's RESOLVED origin is checked against the page origin before the fetch is issued; an
//     off-origin one is REFUSED, never retried credential-less and never answered from a
//     recording.  It carries no bearer material and is not a stand-in for the deck's real OAuth
//     2.1 scheme.
//
// See the "CREDENTIAL BOUNDARY" note at `createLiveTransport`.
//
// NO TIMERS, NO POLLING, NO DOM.  Like fixture-bridge.mjs this module contains no setInterval /
// setTimeout, reads no `limits['poll-interval-ms']` (reserved to Lake), touches no DOM node and
// produces no markup.  Every string it surfaces is plain text for a textContent sink.
//
// ================================================================================================

import {
  emptyDrawnGraph,
  ingestOpen,
  ingestNeighboursPage,
} from '../drawn-graph.mjs';

import { sceneFrom } from './fixture-bridge.mjs';

// ------------------------------------------------------------------------------------------ mode

/**
 * The ONLY live-mode marker this module can produce.
 *
 * Deliberately a single literal, mirroring i2_binding.py:62-64: a fixture response can never be
 * labelled with it because no code path here produces one.  It records that the substance came
 * over HTTP from the named origin in THIS browser tab.  It does NOT assert that the backend is
 * correct, complete, or that any particular route exists.
 */
export const MODE = 'live-http-i3';

// -------------------------------------------------------------------------------------- the seam

/**
 * ROUTE_PREFIX, verbatim from routes.py:30.
 *
 * The full path is PREFIX + endpoint name, exactly as Route.__init__ builds it at routes.py:98.
 */
export const I3_ROUTE_PREFIX = '/atomspace/api/';

/**
 * The three I3 endpoints this bridge uses, in the order the card path walks them.
 *
 * `id` is the K8 endpoint id, carried on every error and result so a failure can be attributed to
 * a step without guessing.  `method` is GET for all three (routes.py:6: no endpoint accepts a
 * body).  This is NOT the full I3 surface — I3-01 `status`, I3-09 `health` and the rest exist but
 * are not part of lookup -> open -> neighbours and are not requested here.
 */
export const I3_ENDPOINTS = Object.freeze({
  lookup: Object.freeze({ id: 'I3-10', name: 'lookup', method: 'GET', path: `${I3_ROUTE_PREFIX}lookup` }),
  open: Object.freeze({ id: 'I3-02', name: 'open', method: 'GET', path: `${I3_ROUTE_PREFIX}open` }),
  neighbours: Object.freeze({ id: 'I3-03', name: 'neighbours', method: 'GET', path: `${I3_ROUTE_PREFIX}neighbours` }),
});

/**
 * The nine outcomes, closed set, verbatim from adapter.py:36-51.
 *
 * The set being CLOSED is load-bearing: an outcome outside the nine is a PROTOCOL VIOLATION and
 * the body must not be passed on (adapter.py:109-114, :752-753).  `checkOutcome` enforces that
 * here too, so a backend answering something new cannot quietly become a drawn graph.
 */
export const NINE_OUTCOMES = Object.freeze([
  'ok', 'ok, partial', 'empty', 'unknown', 'excluded', 'not ready', 'degraded', 'unavailable', 'reload',
]);

/**
 * The envelope's six fields, in the order VIEW emits them (adapter.py:755-767).
 *
 * Key order is load-bearing end to end (LIVE-TRANSPORT.md:158-165).  This list is used only to
 * CHECK presence; nothing here reorders or rewrites a body.
 */
export const ENVELOPE_FIELDS = Object.freeze([
  'outcome', 'epoch', 'position', 'read-at', 'schema-version', 'limits',
]);

/**
 * The outcomes on which the state triple (epoch / position / read-at) is legally all-null.
 *
 * adapter.py:53-55 NO_STATE_OUTCOMES, and record_store.py:196-201 `no_state_envelope`, which
 * returns the three "all present and exactly None (JSON null). A known epoch is never reported".
 * An all-null triple on ANY OTHER outcome is a protocol violation, not a degraded reading.
 */
export const NO_STATE_OUTCOMES = Object.freeze(['not ready', 'unavailable']);

/**
 * DISTANCE_SATURATION, verbatim from adapter.py:78 — A DECK-SIDE FACT, RECORDED HERE AND NEVER
 * APPLIED HERE.
 *
 * The DECK saturates `distance` at 2: `adapter.py:152-161` `parse_distance` returns
 * `min(parse_nonnegative_int(raw, "distance"), DISTANCE_SATURATION)`, invoked server-side at
 * `adapter.py:992` (I3-02 `open`) and `adapter.py:1262` (I3-03 `neighbours`, "validated,
 * saturated, then discarded").  `routes.py:145` declares the input as "non-negative int; default
 * 0; saturated at 2; NEVER forwarded" — saturated BY THE DECK, on the deck's side of the wire.
 *
 * THE CLIENT DOES NOT PRE-CLAMP.  K10 §4.2 (`contracts/k10-client-protocol-v0.md:208-214`) is
 * explicit: "The client sends `d` UNCLAMPED — every non-negative integer is accepted on the wire,
 * and the deck saturates at 2 before applying the table.  The saturation is K8's derivation, not
 * K10's: this contract states no cap, clamp or saturation on `d` ... and the client does not
 * pre-clamp and does not re-own the rule."  So this constant is DOCUMENTATION of what the deck
 * will do to a value, not an operation this module performs on one; `Math.min` appears nowhere in
 * this module's distance path.  `distance` has NO I2 counterpart and never reaches the store
 * (adapter.py:156-157) — a deck-internal mapping fact that does NOT license omitting it from the
 * request.
 */
export const DISTANCE_SATURATION = 2;

// ------------------------------------------------------------------------------------ error types

/**
 * Base class for every live-transport failure.
 *
 * `message` is always a plain, specific, text-only sentence safe for a textContent sink: no
 * markup, no HTML fragment, no stack, and never a raw response body.  `endpointId` attributes the
 * failure to an I3 step.  Subclasses are what let a caller tell a BACKEND-NOT-READY apart from a
 * REFUSAL apart from a GENUINE ERROR without string-matching a message.
 */
export class LiveBridgeError extends Error {
  constructor(message, { endpointId = null, cause = undefined } = {}) {
    super(message, cause === undefined ? undefined : { cause });
    this.name = 'LiveBridgeError';
    this.endpointId = endpointId;
  }
}

/** A request was never attempted because this module's own configuration is absent or invalid. */
export class LiveConfigurationUnresolved extends LiveBridgeError {
  constructor(message) {
    super(message);
    this.name = 'LiveConfigurationUnresolved';
  }
}

/** The caller's argument is malformed; no request was made.  Mirrors adapter.py's MalformedInput. */
export class LiveMalformedInput extends LiveBridgeError {
  constructor(message, opts) {
    super(message, opts);
    this.name = 'LiveMalformedInput';
  }
}

/**
 * The request left the browser and the attempt FAILED at the transport layer.
 *
 * This is NOT an outcome and is deliberately NOT turned into the `unavailable` envelope: the
 * client has no store answer, so it reports a transport fact instead of fabricating a store fact.
 *
 * `status` is the real HTTP status (0 when the fetch itself rejected), `statusText` the real
 * reason phrase, `contentType` the real Content-Type, `bodySnippet` a BOUNDED, plain-text prefix
 * of the real body (never markup, never injected anywhere but textContent), and `classification`
 * one of the strings in `TRANSPORT_CLASSIFICATIONS`.
 */
export class LiveTransportFailed extends LiveBridgeError {
  constructor(message, { endpointId, url, status, statusText, contentType, bodySnippet, classification, cause } = {}) {
    super(message, { endpointId, cause });
    this.name = 'LiveTransportFailed';
    this.url = url ?? null;
    this.status = status ?? null;
    this.statusText = statusText ?? null;
    this.contentType = contentType ?? null;
    this.bodySnippet = bodySnippet ?? null;
    this.classification = classification ?? 'unclassified';
  }
}

/**
 * The backend answered, but with something outside the I3 contract.
 *
 * An outcome outside the nine, a missing envelope field, or an all-null state triple on an
 * outcome that may not carry one.  The body is NOT passed on (adapter.py:109-114).
 */
export class LiveProtocolViolation extends LiveBridgeError {
  constructor(message, { endpointId, detail } = {}) {
    super(message, { endpointId });
    this.name = 'LiveProtocolViolation';
    this.detail = detail ?? null;
  }
}

/**
 * Transport-failure classifications.
 *
 * `route-absent` is the one that matters most here and it is deliberately NOT an auth result:
 * LIVE-TRANSPORT.md:28-30 and :470 record that the K8 §5.1 I3 surface `/atomspace/api/<endpoint>`
 * is NOT DEPLOYED on the dev host and that both probed paths returned 404 Decko bad-address HTML
 * (LIVE-TRANSPORT.md:223-224).  live_store.py's `_classify` makes the same call: "Do not treat as
 * an auth result. This path is not deployed."
 */
export const TRANSPORT_CLASSIFICATIONS = Object.freeze([
  'network-unreachable',   // the fetch itself rejected: DNS, TLS, connection, or CORS blocked it
  'route-absent',          // 404, or any non-JSON content type: the route is not deployed here
  'unauthenticated',       // 401
  'not-permitted',         // 403
  'backend-error',         // 5xx
  'bad-transport-contract',// 2xx that is not application/json
  'non-json-body',         // declared JSON, did not parse
  'json-not-an-object',    // parsed, but not a JSON object
  'off-origin-session-refused', // session mode, resolved request origin is not the page's origin
  'unclassified',          // any other status
]);

// ------------------------------------------------------------------- the two credential branches

/**
 * The TWO credential branches.  There is no third, and neither is ever selected implicitly.
 *
 *   * `none` — the ORIGINAL and still the DEFAULT branch.  `credentials: 'omit'` on every request,
 *     so no cookie and no HTTP-auth state leaves the browser even if the browser holds some for
 *     that origin.  This is the ONLY branch permitted cross-origin.
 *   * `decko-session` — the browser's EXISTING Decko session cookie is allowed to ride along,
 *     and ONLY to an EXPLICITLY SELECTED SAME-ORIGIN backend.  `credentials: 'same-origin'` is
 *     set, which is the standards-level way to say "send the cookie the user already has for this
 *     origin, and nothing anywhere else": the browser itself will not attach it cross-origin.
 *
 * WHAT NEITHER BRANCH EVER DOES.  Neither branch has a token parameter, reads a token-shaped
 * value from anywhere, or sends an `Authorization` header.  The deck's real scheme is an OAuth 2.1
 * RS256 per-real-user Bearer JWT (LIVE-TRANSPORT.md:171-178) and a browser demo page is the wrong
 * place to hold one.  `decko-session` is NOT that scheme and does not stand in for it: it carries
 * no bearer material of its own and can only reuse a cookie the user's browser already holds.
 *
 * THERE IS NO FALLBACK BETWEEN THEM.  A `decko-session` request whose resolved origin is not the
 * page's origin is REFUSED BEFORE THE FETCH.  It is never retried credential-less, never
 * downgraded to `none`, and never answered from a recording.
 */
export const CREDENTIAL_MODES = Object.freeze({
  none: 'none',
  deckoSession: 'decko-session',
});

/** The credential branch used when the caller names none.  Credential-less, by construction. */
export const DEFAULT_CREDENTIAL_MODE = CREDENTIAL_MODES.none;

/**
 * The `credentials` fetch option each branch sends.  Frozen so a caller cannot retarget it.
 *
 * `same-origin` is deliberately NOT `include`.  `include` would ask the browser to attach cookies
 * cross-origin too, which is exactly the thing this branch must not be able to do even if the
 * origin check below were somehow wrong.  `same-origin` makes the browser a second enforcer of
 * the same rule, so the cookie boundary does not rest on this module's check alone.
 */
export const CREDENTIAL_FETCH_OPTION = Object.freeze({
  [CREDENTIAL_MODES.none]: 'omit',
  [CREDENTIAL_MODES.deckoSession]: 'same-origin',
});

/**
 * Normalise a page/backend origin string to its ORIGIN, or throw.
 *
 * Rejects a URL carrying userinfo outright: `http://user:pass@host` is forbidden here because a
 * URL is not a place for a secret, and because `new URL()` would otherwise happily keep it and
 * `fetch` would send it as HTTP-auth state.
 *
 * Returns the `URL.origin` string, which is already scheme + host + normalised port: the default
 * port is dropped, the host is lowercased, and `http://H:80` and `http://h` compare equal. That
 * normalisation is why the comparison below is a safe string equality and not a host substring
 * test (which `evil-127.0.0.1.example.com` would defeat).
 */
export function normalizeOrigin(raw, label = 'origin') {
  if (typeof raw !== 'string' || raw === '') {
    throw new LiveConfigurationUnresolved(`${label} must be a non-empty absolute origin string`);
  }
  let parsed;
  try {
    parsed = new URL(raw);
  } catch {
    throw new LiveConfigurationUnresolved(`${label} is not an absolute URL: ${raw}`);
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    throw new LiveConfigurationUnresolved(`${label} must be http or https; got ${parsed.protocol}`);
  }
  if (parsed.username !== '' || parsed.password !== '') {
    throw new LiveConfigurationUnresolved(
      `${label} must not carry credentials in the URL. A URL is not a place for a secret.`,
    );
  }
  return parsed.origin;
}

/**
 * Resolve ONE request URL to the ORIGIN the browser would really send it to.
 *
 * This is the function the session branch gates on, and it is applied to EVERY request rather
 * than to the configured backend string once.  The distinction matters: a transport is configured
 * with a base, but what leaves the browser is a URL, and the two are not the same claim.  A
 * root-relative path, a protocol-relative `//elsewhere/...`, an absolute URL, a `..` traversal
 * and an endpoint string that smuggles in its own origin all resolve differently, and only the
 * resolved value says where the cookie would go.
 *
 * `new URL(url, base)` is the browser's OWN resolution algorithm, so this reports what `fetch`
 * would actually do rather than a re-implementation that could disagree with it:
 *   * `'/atomspace/api/open'`      -> the base's origin
 *   * `'//evil.example/x'`         -> scheme-relative: the BASE'S SCHEME, EVIL'S HOST -> off-origin
 *   * `'http://evil.example/x'`    -> evil's origin -> off-origin
 *   * `'/a/../../b'`               -> still the base's origin (traversal cannot change an origin)
 *
 * @returns {{url: string, origin: string, sameOrigin: boolean}}
 */
export function resolveRequestOrigin(url, pageOrigin) {
  const base = normalizeOrigin(pageOrigin, 'page origin');
  let parsed;
  try {
    parsed = new URL(url, base);
  } catch {
    throw new LiveConfigurationUnresolved(`request URL cannot be resolved against ${base}: ${url}`);
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    throw new LiveConfigurationUnresolved(
      `request URL must resolve to http or https; got ${parsed.protocol} for ${url}`,
    );
  }
  if (parsed.username !== '' || parsed.password !== '') {
    throw new LiveConfigurationUnresolved(
      `request URL must not carry credentials in the URL; got userinfo in ${url}`,
    );
  }
  return Object.freeze({
    url: parsed.href,
    origin: parsed.origin,
    sameOrigin: parsed.origin === base,
  });
}

/**
 * The SESSION-BRANCH ORIGIN GATE, as a function, so the exact code the transport runs per
 * request is directly unit-testable.
 *
 * `createLiveTransport`'s `request` calls THIS for every session-branch request, before any
 * fetch. It is exported because the frozen `I3_ENDPOINTS` set cannot currently produce an
 * off-origin URL from a validated base — which is the point of validating the base — so without
 * an exported gate the per-request enforcement could only be asserted indirectly. Testing it
 * here tests the real path rather than a re-implementation of it.
 *
 * Throws `LiveTransportFailed` with classification `off-origin-session-refused`, carrying
 * `status: 0` because NOTHING WAS SENT: this is a refusal, not a failed attempt, and it is
 * deliberately distinct from the backend's own `unauthenticated` (401) and `not-permitted` (403)
 * answers. Returns the resolved descriptor when the request is allowed.
 */
export function assertSessionOriginAllowed(url, pageOrigin, endpoint = { id: 'I3', name: 'request' }) {
  const resolved = resolveRequestOrigin(url, pageOrigin);
  if (!resolved.sameOrigin) {
    throw new LiveTransportFailed(
      `${endpoint.id} ${endpoint.name}: REFUSED BEFORE SENDING. credentialMode `
      + `"${CREDENTIAL_MODES.deckoSession}" is same-origin only, and ${url} resolves to `
      + `${resolved.origin}, which is not this page's origin ${normalizeOrigin(pageOrigin)}. The `
      + 'Decko session cookie was not sent, no request was made, and this was NOT retried '
      + 'credential-less. No store answer was received, so no outcome is reported.',
      {
        endpointId: endpoint.id,
        url,
        status: 0,
        classification: 'off-origin-session-refused',
      },
    );
  }
  return resolved;
}

// ------------------------------------------------------------------------------- encoding the seam

const HEX32 = /^[0-9a-f]{32}$/;

/**
 * Percent-encode ONE query-parameter value, exactly once.
 *
 * routes.py:246 requires `name` to arrive "percent-encoded; %7E if it starts ~" and adapter.py:3-5
 * states that splitting the query string and percent-decoding exactly once is the TRANSPORT's job
 * and not the adapter's.  So:
 *
 *   * `encodeURIComponent` does the encoding, and it is applied exactly ONCE — never to a value
 *     that has already been encoded.
 *   * `encodeURIComponent` leaves `~` ALONE, which is not good enough: a bare name that begins
 *     `~` would be read as an ADDRESS PREFIX.  A leading `~` is therefore forced to `%7E`.  The
 *     adapter refuses to strip a leading `~` precisely so that `~kAlpha` stays the NAME `~kAlpha`
 *     and never becomes the key `Alpha` (adapter.py:246-285, :259-264); encoding it keeps that
 *     promise reachable over the wire.
 *   * Slashes, spaces, `+`, unicode and control characters are all handled by
 *     `encodeURIComponent`.  `+` matters: it must go out as `%2B` or a form-decoder would read it
 *     as a space.  Nothing is normalised, folded or trimmed — the name is sent as given.
 *
 * @param {string} value
 * @returns {string}
 */
export function encodeQueryValue(value) {
  if (typeof value !== 'string') {
    throw new LiveMalformedInput(`query value must be a string; got ${typeof value}`);
  }
  const encoded = encodeURIComponent(value);
  return encoded.startsWith('~') ? `%7E${encoded.slice(1)}` : encoded;
}

/**
 * Turn a card NAME into the `name` parameter of I3-10 `lookup`.
 *
 * Refuses exactly what the adapter refuses before any request is made (adapter.py:235-236, :278-279):
 * a missing name, a non-string, and the empty string.  Nothing is defaulted.
 */
export function lookupNameParam(name) {
  if (name === null || name === undefined) throw new LiveMalformedInput('name: required');
  if (typeof name !== 'string' || name === '') {
    throw new LiveMalformedInput('name: empty or non-string address');
  }
  return encodeQueryValue(name);
}

/**
 * Build the `participant` ADDRESS parameter for I3-02 / I3-03.
 *
 * THE WIRE HAS EXACTLY THREE ADDRESS FORMS (routes.py:144, adapter.py:164-190):
 *   `~k<key>`      -> {"key": <text>}      the `~k` is stripped by the adapter
 *   `~d<32 hex>`   -> {"digest": <hex>}    validated against adapter.py:89 `[0-9a-f]{32}\Z`
 *   `<name>`       -> resolved deck-side
 *
 * In-process, `real_card_path` hands steps 2 and 3 the KIND-PRESERVING 2-TUPLE
 * `("key", lookup["key"])` (i2_binding.py:482) because that is the only form that cannot be
 * misread (adapter.py:219-226).  A tuple has NO WIRE REPRESENTATION, so over HTTP the
 * kind-preserving equivalent is `~k<key>`, and that is what this bridge sends after a lookup —
 * never the bare name a second time.  The `~k` is STRUCTURAL and stays literal; the key TEXT is
 * percent-encoded, including a `~` of its own.
 *
 * @param {{kind: 'key'|'digest'|'name', text: string}} address
 * @returns {string} the percent-encoded parameter value
 */
export function addressParam(address) {
  if (!address || typeof address !== 'object') {
    throw new LiveMalformedInput('participant: address must be {kind, text}');
  }
  const { kind, text } = address;
  if (typeof text !== 'string' || text === '') {
    throw new LiveMalformedInput('participant: empty or non-string address');
  }
  if (kind === 'key') return `~k${encodeQueryValue(text)}`;
  if (kind === 'digest') {
    if (!HEX32.test(text)) {
      throw new LiveMalformedInput('participant: ~d needs 32 lowercase hex digits');
    }
    return `~d${text}`;
  }
  if (kind === 'name') return encodeQueryValue(text);
  throw new LiveMalformedInput(`participant: unknown address kind ${String(kind)}`);
}

/** The adapter's own `distance` grammar: a bare non-negative DECIMAL literal (adapter.py:87). */
const DECIMAL_INT = /^[0-9]+$/;

/** Digits in int64's maximum, so an oversized literal is out of range by inspection (adapter.py:92). */
const INT64_MAX_DIGITS = 19;

/**
 * VALIDATE `distance` and return the NUMBER, UNSATURATED.  The client validates FORMAT ONLY.
 *
 * THE SETTLED DIVISION OF LABOUR IS TWO RULES, and this function owns exactly the first:
 *
 *   1. CLIENT — strict format validation.  A non-negative decimal integer passes through
 *      UNTOUCHED; anything else is REFUSED (`LiveMalformedInput`).  The client DOES NOT PRE-CLAMP.
 *   2. DECK — saturates at 2 (adapter.py:78, :152-161; routes.py:145).  Not this layer's job.
 *
 * K10 §4.2 (`contracts/k10-client-protocol-v0.md:208-214`) states it verbatim: `distance` is a
 * "non-negative integer with default 0.  The client sends `d` UNCLAMPED — every non-negative
 * integer is accepted on the wire, and the deck saturates at 2 before applying the table.  The
 * saturation is K8's derivation, not K10's: this contract states no cap, clamp or saturation on
 * `d` ... and the client does not pre-clamp and does not re-own the rule."  So a `distance` of 9
 * is a LEGAL WIRE VALUE and is sent as 9; the deck, not the client, turns it into 2.  Clamping
 * here would pre-saturate a numerically valid value, and the honest fix for "the UI must not show
 * a request it did not make" is to SEND the value the caller asked for — not to clamp and then
 * paper over the mismatch at the display layer.  With no client clamp, the value displayed and
 * the value sent are the SAME value and there is nothing to reconcile.
 *
 * MALFORMED IS MALFORMED, NOT UNSATISFIABLE.  K10 §4.2
 * (`k10-client-protocol-v0.md:220-222`): "A `distance` that is not a non-negative decimal integer
 * makes the request MALFORMED, not unsatisfiable: it is handled on the refusal path and is NEVER
 * one of the outcomes this client switches on."  So:
 *
 *   * ABSENT -> 0.  Not 1, not "whatever the caller last used", not omitted from the request
 *     (adapter.py:152-161 `parse_distance` defaults to 0 — K8's derivation, not K10's).
 *   * MALFORMED -> REFUSED on the refusal path, never coerced into a value the caller did not
 *     ask for and never turned into a store outcome.  A string must match the adapter's own
 *     decimal grammar: JS `Number()` would otherwise accept `''`, `' 2'`, `'+2'`, `'2.0'`,
 *     `'1e1'` and `'0x2'` and silently invent a value for each.  An over-long literal is out of
 *     range by digit count rather than by conversion (adapter.py:128-140).
 *   * LEADING ZEROES are NOT a range error: `'007'` is the integer 7 (adapter.py:138).
 *
 * @param {number|string|null|undefined} distance
 * @returns {number} a non-negative integer, exactly as the caller asked — NOT saturated
 */
export function validateDistance(distance) {
  if (distance === null || distance === undefined) return 0;
  let n;
  if (typeof distance === 'string') {
    if (!DECIMAL_INT.test(distance)) {
      throw new LiveMalformedInput(
        `distance: non-negative decimal integer required; got ${JSON.stringify(distance)}`,
      );
    }
    const significant = distance.replace(/^0+/, '');
    if (significant.length > INT64_MAX_DIGITS) throw new LiveMalformedInput('distance: out of range');
    n = significant === '' ? 0 : Number(significant);
  } else if (typeof distance === 'number') {
    if (!Number.isSafeInteger(distance) || distance < 0) {
      throw new LiveMalformedInput(`distance: non-negative integer required; got ${String(distance)}`);
    }
    n = distance;
  } else {
    throw new LiveMalformedInput(`distance: non-negative integer required; got ${typeof distance}`);
  }
  return n;
}

/**
 * Render the VALIDATED `distance` as its wire string, UNCLAMPED.
 *
 * This is the only function that puts a `distance` on the wire.  It validates the format before
 * rendering, so no MALFORMED value can leave the browser, and it saturates nothing, so the value
 * on the wire is the value the caller asked for (K10 §4.2).
 */
export function distanceParam(distance) {
  return String(validateDistance(distance));
}

/**
 * Assemble the complete query string for one I3 request.
 *
 * ORDERED, REPEATED-KEY-AWARE, AND ENCODED EXACTLY ONCE.  The repeated parameters keep their
 * literal bracketed wire names — `focus[]`, `kind[]`, `card-type[]`, `direction[]` (routes.py:128-130,
 * :146-147) — and the budget parameters keep their literal DOTTED names, `budget.elements` and
 * `budget.connections` (routes.py:133-134).  Those are the names on the wire; they are not
 * camelCased, and the brackets are percent-encoded in the KEY as `%5B%5D` so the query string is
 * well-formed.
 *
 * A parameter that is absent is OMITTED, never sent empty: `translate_budget` reports "none
 * reported" when neither dotted input is present (adapter.py:304-323), and an empty `budget` is
 * not the same request as no budget.
 *
 * @param {Array<[string, string]>} pairs  already-encoded VALUES, raw KEYS
 * @returns {string} '' when there are no pairs, otherwise '?k=v&k=v'
 */
export function encodeI3Query(pairs) {
  if (!Array.isArray(pairs) || pairs.length === 0) return '';
  const parts = [];
  for (const pair of pairs) {
    if (!Array.isArray(pair) || pair.length !== 2) {
      throw new LiveMalformedInput('query pairs must be [key, encodedValue] tuples');
    }
    const [key, encodedValue] = pair;
    if (typeof key !== 'string' || key === '') {
      throw new LiveMalformedInput('query key must be a non-empty string');
    }
    if (typeof encodedValue !== 'string') {
      throw new LiveMalformedInput(`query value for ${key} must be a string`);
    }
    parts.push(`${encodeURIComponent(key)}=${encodedValue}`);
  }
  return `?${parts.join('&')}`;
}

/** Repeated-parameter helper: one [key, encodedValue] pair per entry, in the caller's order. */
function repeatedPairs(key, values) {
  const out = [];
  if (values === null || values === undefined) return out;
  if (!Array.isArray(values)) throw new LiveMalformedInput(`${key}: array required`);
  for (const v of values) {
    if (typeof v !== 'string' || v === '') {
      throw new LiveMalformedInput(`${key}: entries must be non-empty strings`);
    }
    out.push([key, encodeQueryValue(v)]);
  }
  return out;
}

/**
 * The query pairs for I3-10 `lookup`.
 *
 * Exactly one parameter: `name` (routes.py:245-247).  It is a BARE NAME, never an address: `~k`
 * and `~d` are not a grammar for this input (routes.py:246-247 citing QD-9 / cpd010), which is
 * why a leading `~` is encoded rather than left to be misread.
 */
export function lookupPairs({ name }) {
  return [['name', lookupNameParam(name)]];
}

/**
 * The query pairs for I3-02 `open`.
 *
 * `participant` is required; `distance` is sent always (its own default is '0'); `focus[]`,
 * `kind[]`, `card-type[]` and `direction[]` are repeated and omitted when empty; the two budget
 * parameters are sent only when the caller supplies them, and are ADVISORY — a client cannot
 * raise a server ceiling by claiming a large budget (adapter.py:310-313).
 *
 * NARROWING IS KNOWN-REFUSED BY THE INTEGRATED BACKEND.  `kind[]` / `card-type[]` / `direction[]`
 * draw I2Refused("I2-09", "narrowing (kind / card-type / direction) is not implemented in this
 * slice") from the integrated store (i2_read.py:681-684, :860).  They are implemented here so the
 * request is expressible and the refusal is OBSERVED rather than avoided, but a caller that sends
 * them should expect a refusal, not silence.
 */
export function openPairs({ participant, distance = null, focus = null, kind = null, cardType = null, direction = null, budget = null }) {
  const pairs = [['participant', addressParam(participant)]];
  pairs.push(['distance', distanceParam(distance)]);
  pairs.push(...repeatedPairs('focus[]', focus));
  pairs.push(...repeatedPairs('kind[]', kind));
  pairs.push(...repeatedPairs('card-type[]', cardType));
  if (direction !== null && direction !== undefined) {
    if (!Array.isArray(direction)) throw new LiveMalformedInput('direction[]: array required');
    for (const d of direction) {
      if (!Number.isInteger(d) || d < 0) {
        throw new LiveMalformedInput('direction[]: non-negative integer position indexes only');
      }
      pairs.push(['direction[]', String(d)]);
    }
  }
  if (budget !== null && budget !== undefined) {
    if (typeof budget !== 'object') throw new LiveMalformedInput('budget: object required');
    const hasElements = Object.prototype.hasOwnProperty.call(budget, 'elements');
    const hasConnections = Object.prototype.hasOwnProperty.call(budget, 'connections');
    if (!hasElements && !hasConnections) {
      throw new LiveMalformedInput('budget: supply elements and/or connections, or omit budget entirely');
    }
    if (hasElements) {
      if (!Number.isInteger(budget.elements) || budget.elements < 0) {
        throw new LiveMalformedInput('budget.elements: non-negative integer required');
      }
      pairs.push(['budget.elements', String(budget.elements)]);
    }
    if (hasConnections) {
      if (!Number.isInteger(budget.connections) || budget.connections < 0) {
        throw new LiveMalformedInput('budget.connections: non-negative integer required');
      }
      pairs.push(['budget.connections', String(budget.connections)]);
    }
  }
  return pairs;
}

/**
 * The query pairs for I3-03 `neighbours`.
 *
 * `participant` and `bucket` are both required (routes.py:161-162).  `after` is an OPAQUE CURSOR:
 * it is passed through verbatim and NEVER parsed, inspected, incremented or reconstructed
 * (routes.py:163).  The cursor a caller holds comes from a previous response's
 * `omitted.continue[].cursor`; this module does not build one.
 *
 * `distance` IS AN I3-03 INPUT AND IS SENT.  routes.py:164 declares it on this route and
 * i2_binding.py:492-498 states the rule verbatim: "`distance` is sent on BOTH I3-02 `open` and
 * I3-03 `neighbours`, per K10 §4.2 (k10-client-protocol-v0.md:203-206) and K8 draft-2 §5.5's
 * I3-03 Inputs cell (k8-draft-2.md:567, Addendum 1 §4).  VIEW's own I3-03 handler validates and
 * saturates the value and then discards it before the I2 call (adapter.py:1226) because it has no
 * I2 counterpart; that is a deck-internal mapping fact and does NOT license omitting it from the
 * request."  It is sent ALWAYS, with the same default and the same FORMAT-ONLY validation as on
 * `open` (distanceParam — validated, never client-saturated), so one input has one rule on both
 * routes.  I3-10 `lookup` takes NO `distance` (routes.py:245-247) and `lookupPairs` correctly
 * sends none; that absence is right and stays.
 */
export function neighboursPairs({ participant, bucket, after = null, distance = null, kind = null, cardType = null, direction = null }) {
  if (typeof bucket !== 'string' || bucket === '') {
    throw new LiveMalformedInput('bucket: non-empty link-type string required');
  }
  const pairs = [
    ['participant', addressParam(participant)],
    ['bucket', encodeQueryValue(bucket)],
  ];
  if (after !== null && after !== undefined) {
    // An opaque cursor may be a string on the wire or a JSON object in a previous body.  Either is
    // forwarded without interpretation; an object is serialised, not rewritten.
    const opaque = typeof after === 'string' ? after : JSON.stringify(after);
    pairs.push(['after', encodeQueryValue(opaque)]);
  }
  pairs.push(['distance', distanceParam(distance)]);
  pairs.push(...repeatedPairs('kind[]', kind));
  pairs.push(...repeatedPairs('card-type[]', cardType));
  if (direction !== null && direction !== undefined) {
    if (!Array.isArray(direction)) throw new LiveMalformedInput('direction[]: array required');
    for (const d of direction) {
      if (!Number.isInteger(d) || d < 0) {
        throw new LiveMalformedInput('direction[]: non-negative integer position indexes only');
      }
      pairs.push(['direction[]', String(d)]);
    }
  }
  return pairs;
}

// --------------------------------------------------------------------------- response validation

/** Bounded, plain-text prefix of a real body.  Never markup, never a template interpolation. */
function snippet(text, limit = 240) {
  if (typeof text !== 'string') return null;
  const flat = text.replace(/\s+/g, ' ').trim();
  return flat.length <= limit ? flat : `${flat.slice(0, limit)}…`;
}

/**
 * Check a parsed body against the I3 contract, WITHOUT rewriting it.
 *
 * Returns the body unchanged on success.  Throws LiveProtocolViolation otherwise.  Three checks,
 * all of them things VIEW itself enforces:
 *   1. the outcome is one of the nine (adapter.py:109-114, :752-753)
 *   2. the six envelope fields are PRESENT (presence, not truthiness — `null` is a legal value
 *      for three of them on the no-state outcomes)
 *   3. an all-null state triple appears ONLY on `not ready` / `unavailable`
 *      (adapter.py:53-55, :810-812)
 *
 * It does NOT check `limits`, `health`, or any payload key: those are the backend's to supply and
 * the ingestion module's to read.  Nothing absent is filled in.
 */
export function checkI3Body(body, endpointId) {
  if (body === null) return null; // a refusal: no outcome is invented for it (drawn-graph.mjs)
  if (typeof body !== 'object' || Array.isArray(body)) {
    throw new LiveProtocolViolation(
      `${endpointId}: response body is not a JSON object`,
      { endpointId, detail: typeof body },
    );
  }
  const outcome = body.outcome;
  if (!NINE_OUTCOMES.includes(outcome)) {
    throw new LiveProtocolViolation(
      `${endpointId}: store answered an outcome outside the nine: ${JSON.stringify(outcome)}`,
      { endpointId, detail: outcome },
    );
  }
  const missing = ENVELOPE_FIELDS.filter((f) => !Object.prototype.hasOwnProperty.call(body, f));
  if (missing.length > 0) {
    throw new LiveProtocolViolation(
      `${endpointId}: envelope is missing ${missing.join(', ')}`,
      { endpointId, detail: missing },
    );
  }
  const triple = [body.epoch, body.position, body['read-at']];
  const allNull = triple.every((v) => v === null);
  if (allNull && !NO_STATE_OUTCOMES.includes(outcome)) {
    throw new LiveProtocolViolation(
      `${endpointId}: epoch, position and read-at are all null on outcome "${outcome}", `
      + `which may not carry a no-state triple`,
      { endpointId, detail: outcome },
    );
  }
  return body;
}

/**
 * Is this body a BACKEND-NOT-READY answer?
 *
 * `not ready` is an OUTCOME, in band, with the state triple all-null (record_store.py:196-201).
 * It is NOT a transport failure and NOT a refusal: the backend answered, honestly, that it has no
 * published state.  A caller shows it as itself and draws nothing — it must not be collapsed into
 * an error, and an empty canvas alone is not an acceptable rendering of it.
 */
export function isNotReady(body) {
  return Boolean(body) && body.outcome === 'not ready';
}

/** Does this body report a store state at all?  (Mirrors drawn-graph.mjs STATE_REPORTING_OUTCOMES.) */
export function reportsState(body) {
  return Boolean(body) && ['ok', 'ok, partial', 'degraded'].includes(body.outcome);
}

// ----------------------------------------------------------------------------------- the transport

function classifyHttp(status, contentType) {
  const ct = (contentType || '').toLowerCase();
  const isJson = ct.includes('application/json');
  if (status === 404) return 'route-absent';
  if (status === 401) return 'unauthenticated';
  if (status === 403) return 'not-permitted';
  if (status >= 500) return 'backend-error';
  if (status >= 200 && status < 300) return isJson ? null : 'bad-transport-contract';
  return 'unclassified';
}

/**
 * Create an INJECTED-TRANSPORT I3 client.
 *
 * INJECTION IS THE POINT.  `fetchImpl` is a required constructor argument, not a module-level
 * `globalThis.fetch` reach.  That is what makes the whole request/response seam unit-testable
 * without a server, and it is why the tests in src/live-bridge.transport.test.mjs can assert the
 * exact URL, the exact parameter encoding and the exact handling of every answer shape while
 * being honest that they are NOT a real-server integration test.
 *
 * CREDENTIAL BOUNDARY — TWO EXPLICIT BRANCHES, NO FALLBACK BETWEEN THEM.
 *
 * `credentialMode` selects one of `CREDENTIAL_MODES`, and it is `none` unless the caller names
 * the other one.  There is no auto-detection, no "try with the session, retry without", and no
 * path by which an off-origin request silently becomes a credential-less one.
 *
 *   * `'none'` (DEFAULT, unchanged behaviour): `credentials: 'omit'` on every request, so no
 *     cookie and no HTTP-auth state is sent even if the browser holds some for that origin.  This
 *     is the ONLY branch allowed to address a cross-origin backend.
 *   * `'decko-session'`: `credentials: 'same-origin'`, which lets the browser attach the Decko
 *     session cookie the user ALREADY HOLDS for this origin — and, per the fetch standard, attach
 *     it only same-origin.  Selecting this branch REQUIRES `pageOrigin`, and EVERY request is
 *     checked against it.
 *
 * NO TOKENS, IN EITHER BRANCH.  There is no token, key, password or header parameter anywhere in
 * this factory, and `Authorization` is never sent.  `Accept: application/json` remains the only
 * header.  The deck's real scheme is an OAuth 2.1 RS256 per-real-user Bearer JWT
 * (LIVE-TRANSPORT.md:171-178); a browser demo page is the wrong place to hold one, and the
 * session branch does not pretend to be it — it reuses a cookie or it refuses.
 *
 * ORIGIN ENFORCEMENT IS ON THE RESOLVED REQUEST ORIGIN, PER REQUEST.  The session branch does NOT
 * gate on "is the backend string empty".  An empty `baseUrl` is only a convenient way to SAY
 * same-origin; what is actually enforced is that the URL this transport is about to hand to
 * `fetch`, resolved against `pageOrigin` by the browser's own algorithm, has `pageOrigin`'s
 * origin.  That holds for an explicitly selected non-empty same-origin backend too, and it
 * catches a protocol-relative, absolute or traversal-bearing endpoint that an empty-string check
 * would wave through.  An off-origin request in session mode is refused BEFORE THE FETCH is
 * issued, with classification `off-origin-session-refused`.
 *
 * REDIRECTS.  `redirect: 'error'` on every request in both branches, so a 3xx is a refusal rather
 * than something followed to an origin this module never examined.  That is what keeps the
 * resolved-origin check meaningful: a followed redirect could otherwise move the effective origin
 * after the check had already passed.
 *
 *   * `baseUrl` is REQUIRED and has NO DEFAULT.  There is no origin guessing, no auto-discovery
 *     and no fallback to a recorded corpus (cf. i2_binding.py:66-69, :221-226).
 *
 * SAME-ORIGIN / LOOPBACK BOUND.  `baseUrl` may be the empty string, meaning "this page's own
 * origin" — the same-origin case, which needs no CORS at all and is the only configuration the
 * local demo server can serve.  A non-empty `baseUrl` must be an absolute http(s) origin and is
 * accepted only when it is a LOOPBACK origin (127.0.0.1 / [::1] / localhost) unless the caller
 * passes `allowNonLoopback: true` explicitly.  Nothing here ever asks a server for a wildcard
 * `Access-Control-Allow-Origin`, and the local demo server sends no CORS headers and refuses
 * OPTIONS with 405 (server.py:268), so a cross-origin live read is a configuration that must be
 * arranged deliberately and visibly, not stumbled into.
 *
 * THE LOOPBACK RULE IS NOT LOOSENED FOR THE SESSION BRANCH, and that is a deliberate tradeoff
 * worth naming.  The loopback restriction exists for a CORS reason (the demo server serves no
 * CORS headers), which does not apply to a same-origin read; one could therefore argue a
 * same-origin non-loopback backend should need no `allowNonLoopback`.  This module does NOT make
 * that argument into a default, because quietly widening which origins a cookie-bearing request
 * may name is exactly the kind of change that should be visible in a caller's arguments.  So:
 * naming a non-loopback origin STRING still requires `allowNonLoopback: true` in both branches.
 * A page already served from a non-loopback origin can still select its own origin with
 * `baseUrl: ''` — unchanged from before this branch existed, since an empty base was never
 * subject to the loopback test.
 *
 * @param {{fetchImpl: Function, baseUrl: string, allowNonLoopback?: boolean, timeoutMs?: number|null,
 *          credentialMode?: string, pageOrigin?: string|null}} options
 */
export function createLiveTransport({
  fetchImpl,
  baseUrl,
  allowNonLoopback = false,
  timeoutMs = null,
  credentialMode = DEFAULT_CREDENTIAL_MODE,
  pageOrigin = null,
} = {}) {
  if (typeof fetchImpl !== 'function') {
    throw new LiveConfigurationUnresolved(
      'live transport needs an injected fetch implementation; pass fetchImpl (no global is read)',
    );
  }
  if (typeof baseUrl !== 'string') {
    throw new LiveConfigurationUnresolved(
      'live transport needs an explicit backend origin; pass baseUrl '
      + "('' means this page's own origin). There is no default and no auto-discovery.",
    );
  }
  const base = baseUrl.replace(/\/+$/, '');
  if (base !== '') {
    let parsed;
    try {
      parsed = new URL(base);
    } catch (cause) {
      throw new LiveConfigurationUnresolved(
        `backend origin is not an absolute URL: ${base}`,
      );
    }
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
      throw new LiveConfigurationUnresolved(
        `backend origin must be http or https; got ${parsed.protocol}`,
      );
    }
    const loopback = ['127.0.0.1', 'localhost', '[::1]', '::1'].includes(parsed.hostname);
    if (!loopback && !allowNonLoopback) {
      throw new LiveConfigurationUnresolved(
        `backend origin ${parsed.origin} is not loopback. A cross-origin live read needs CORS `
        + 'the local demo server does not provide, and must be enabled deliberately with '
        + 'allowNonLoopback: true.',
      );
    }
    if (parsed.pathname !== '/' && parsed.pathname !== '') {
      throw new LiveConfigurationUnresolved(
        `backend origin must carry no path; got ${parsed.pathname}`,
      );
    }
  }

  // --- the credential branch, resolved ONCE at construction and then never re-decided ---------
  if (credentialMode !== CREDENTIAL_MODES.none && credentialMode !== CREDENTIAL_MODES.deckoSession) {
    throw new LiveConfigurationUnresolved(
      `unknown credentialMode "${String(credentialMode)}". The only branches are `
      + `"${CREDENTIAL_MODES.none}" (credentials: omit) and "${CREDENTIAL_MODES.deckoSession}" `
      + '(same-origin Decko session cookie). Neither is guessed and there is no fallback.',
    );
  }
  const sessionBranch = credentialMode === CREDENTIAL_MODES.deckoSession;

  // The session branch cannot be configured without the origin it must be checked against.  A
  // missing pageOrigin is a CONFIGURATION ABSENCE, reported as one, not defaulted to the base and
  // not quietly downgraded to the credential-less branch.
  let sessionPageOrigin = null;
  if (sessionBranch) {
    if (typeof pageOrigin !== 'string' || pageOrigin === '') {
      throw new LiveConfigurationUnresolved(
        `credentialMode "${CREDENTIAL_MODES.deckoSession}" needs an explicit pageOrigin to check `
        + 'every request against (e.g. window.location.origin). There is no default, and an '
        + 'off-origin session request is refused rather than sent credential-less.',
      );
    }
    sessionPageOrigin = normalizeOrigin(pageOrigin, 'pageOrigin');

    // A non-empty base is checked EAGERLY too, so a misconfiguration is reported at construction
    // rather than only at the first request.  This is an ADDITION to the per-request check, never
    // a replacement for it: the per-request check is the one that actually guards the cookie.
    if (base !== '') {
      const baseOrigin = normalizeOrigin(base, 'backend origin');
      if (baseOrigin !== sessionPageOrigin) {
        throw new LiveConfigurationUnresolved(
          `credentialMode "${CREDENTIAL_MODES.deckoSession}" is SAME-ORIGIN ONLY: the selected `
          + `backend ${baseOrigin} is not this page's origin ${sessionPageOrigin}. The Decko `
          + 'session cookie is not sent to another origin, and this request is NOT retried '
          + `credential-less — select the cross-origin backend with credentialMode `
          + `"${CREDENTIAL_MODES.none}" if a credential-less read is what you want.`,
        );
      }
    }
  }

  const credentialsOption = CREDENTIAL_FETCH_OPTION[credentialMode];

  /** The exact absolute-or-root-relative URL for one request.  Exposed so a test can assert it. */
  function urlFor(endpoint, pairs) {
    return `${base}${endpoint.path}${encodeI3Query(pairs)}`;
  }

  /**
   * One I3 request.  Returns the CHECKED WIRE BODY, unaltered.  Throws a typed error otherwise.
   *
   * It never returns a partial, patched or defaulted body, and never substitutes an outcome for a
   * transport fact.
   */
  async function request(endpoint, pairs) {
    const url = urlFor(endpoint, pairs);

    // ---- SESSION BRANCH GATE: refused BEFORE THE FETCH, on the RESOLVED request origin -------
    // This runs per request, not per configuration, and it validates where this URL would really
    // go rather than whether the backend string happens to be empty.  Nothing has left the
    // browser at this point, so a refusal here is a refusal, not a failed attempt.  The gate is
    // `assertSessionOriginAllowed`, exported so this exact check is unit-tested directly.
    if (sessionBranch) {
      assertSessionOriginAllowed(url, sessionPageOrigin, endpoint);
    }

    let res;
    const init = {
      method: endpoint.method,
      headers: { Accept: 'application/json' },
      credentials: credentialsOption,
      mode: 'cors',
      redirect: 'error',
      cache: 'no-store',
    };
    if (timeoutMs !== null && typeof AbortSignal !== 'undefined' && typeof AbortSignal.timeout === 'function') {
      init.signal = AbortSignal.timeout(timeoutMs);
    }
    try {
      res = await fetchImpl(url, init);
    } catch (cause) {
      throw new LiveTransportFailed(
        `${endpoint.id} ${endpoint.name}: the request to ${url} could not be completed `
        + `(${cause && cause.message ? cause.message : 'no reason reported'}). `
        + 'No store answer was received, so no outcome is reported.',
        { endpointId: endpoint.id, url, status: 0, classification: 'network-unreachable', cause },
      );
    }
    if (!res || typeof res.status !== 'number') {
      throw new LiveTransportFailed(
        `${endpoint.id} ${endpoint.name}: the injected transport returned something that is not a `
        + 'Response. No store answer was received.',
        { endpointId: endpoint.id, url, classification: 'bad-transport-contract' },
      );
    }
    const contentType = res.headers && typeof res.headers.get === 'function'
      ? res.headers.get('content-type')
      : null;
    const bad = classifyHttp(res.status, contentType);
    if (bad !== null) {
      let text = null;
      try {
        text = typeof res.text === 'function' ? await res.text() : null;
      } catch { /* a body we cannot read is reported as absent, not as empty */ }
      const detail = bad === 'route-absent'
        ? `The I3 route ${endpoint.path} is not served at this origin. This is a MISSING ROUTE, `
          + 'not an authorisation result.'
        : `HTTP ${res.status}${res.statusText ? ` ${res.statusText}` : ''}.`;
      throw new LiveTransportFailed(
        `${endpoint.id} ${endpoint.name}: ${url} answered ${res.status}`
        + `${res.statusText ? ` ${res.statusText}` : ''} (${contentType || 'no content-type'}). `
        + `${detail} No store answer was received, so no outcome is reported.`,
        {
          endpointId: endpoint.id,
          url,
          status: res.status,
          statusText: res.statusText ?? null,
          contentType,
          bodySnippet: snippet(text),
          classification: bad,
        },
      );
    }
    let parsed;
    let raw = null;
    try {
      raw = typeof res.text === 'function' ? await res.text() : null;
      parsed = raw === null ? await res.json() : JSON.parse(raw);
    } catch (cause) {
      throw new LiveTransportFailed(
        `${endpoint.id} ${endpoint.name}: ${url} answered ${res.status} with a body that is not `
        + 'JSON. No store answer was received.',
        {
          endpointId: endpoint.id,
          url,
          status: res.status,
          statusText: res.statusText ?? null,
          contentType,
          bodySnippet: snippet(raw),
          classification: 'non-json-body',
          cause,
        },
      );
    }
    if (parsed !== null && (typeof parsed !== 'object' || Array.isArray(parsed))) {
      throw new LiveTransportFailed(
        `${endpoint.id} ${endpoint.name}: ${url} answered JSON that is not an object.`,
        {
          endpointId: endpoint.id,
          url,
          status: res.status,
          contentType,
          bodySnippet: snippet(raw),
          classification: 'json-not-an-object',
        },
      );
    }
    return checkI3Body(parsed, endpoint.id);
  }

  return Object.freeze({
    mode: MODE,
    baseUrl: base,
    urlFor,

    /** The credential branch in force.  Fixed at construction; nothing re-decides it per call. */
    credentialMode,

    /** The `credentials` fetch option this branch sends, so a UI can state it without guessing. */
    credentialsOption,

    /** The origin session requests are checked against; `null` in the credential-less branch. */
    pageOrigin: sessionPageOrigin,

    /** I3-10 `lookup`.  Resolves a bare NAME to the store's own key and digest. */
    async lookup(args) {
      return request(I3_ENDPOINTS.lookup, lookupPairs(args));
    },

    /** I3-02 `open`.  One whole read of a participant, its label, properties and buckets. */
    async open(args) {
      return request(I3_ENDPOINTS.open, openPairs(args));
    },

    /** I3-03 `neighbours`.  One page of one bucket, with the store's own cursor when cut. */
    async neighbours(args) {
      return request(I3_ENDPOINTS.neighbours, neighboursPairs(args));
    },
  });
}

// ------------------------------------------------------------------------------- the card path

/**
 * The payload-bearing outcomes: EXACTLY THREE (i2_binding.py:100-120 `PAYLOAD_OUTCOMES`).
 *
 * `ok`, `ok, partial` and `degraded`.  A dependent call MAY be issued on one of these and MUST
 * NOT be issued on any other.
 *
 *   * `ok, partial` is ONE closed-set outcome string (adapter.py:37), not "ok" plus a qualifier,
 *     and it is a SUCCESS carrying a truthful `omitted`.  Treating it as a failure drops a
 *     legitimately paged answer.
 *   * `degraded` IS PAYLOAD-BEARING.  K8 gives its payload column as "full + `health`"
 *     (k8-draft-2.md:486) and defines it as "the store can answer from a published state, and at
 *     least one named domain is not healthy ... a degraded response is a real answer at a real
 *     position and may be drawn" (k8-draft-2.md:961-964).  The adapter's own payload test agrees
 *     (adapter.py:1030 `not in (OK, OK_PARTIAL, DEGRADED)`).  Excluding it would silently drop a
 *     real answer's neighbours.
 *
 * The genuinely NON-payload six are `empty`, `unknown`, `excluded`, `not ready`, `unavailable`
 * and `reload`: each describes an answer with no participant to ask a follow-up question about.
 * This is the same triple `reportsState` reports and the same triple drawn-graph.mjs calls
 * STATE_REPORTING_OUTCOMES; it is named here because the card path GATES on it.
 */
export const PAYLOAD_OUTCOMES = Object.freeze(['ok', 'ok, partial', 'degraded']);

/**
 * The CLIENT's first real card, in three I3 calls — the browser mirror of
 * i2_binding.py:480-549 `real_card_path`.
 *
 * EVERY BEHAVIOUR OF THE PYTHON SEAM IS MIRRORED, deliberately and literally:
 *   * STEP 1'S GATE is a LITERAL STRING COMPARISON on the outcome: `if (lookup.outcome !== 'ok')`.
 *     'ok, partial' does NOT pass; the path stops and `open` / `neighbours` stay null
 *     (i2_binding.py:530-531).
 *   * STEP 3 REQUIRES A PAYLOAD-BEARING STEP 2 (i2_binding.py:509-516, :537-541).  `neighbours`
 *     is a question about a bucket of the participant step 2 opened, so it is only asked when
 *     step 2 actually returned that participant.  On any other outcome step 2's body is returned
 *     TRUTHFULLY AND UNCHANGED with `bucket` and `neighbours` reported as null, no I3-03 request
 *     is issued, and nothing is retried.  THIS HOLDS FOR AN EXPLICIT `bucket` TOO: taking the
 *     bucket from the argument and never looking at step 2's outcome issued step 3 against an
 *     `unknown` or `not ready` open, which is the defect this gate closes.
 *   * Steps 2 and 3 address the participant by the KEY FROM STEP 1, in the kind-preserving form
 *     (i2_binding.py:533) — over HTTP that is `~k<key>`, never the name a second time.
 *   * `distance` IS VALIDATED ONCE, HERE, BEFORE ANY USE (validateDistance), and the validated —
 *     UNSATURATED — value is what both requests carry and what a caller can display.  The client
 *     validates FORMAT ONLY and does not pre-clamp; the DECK saturates at 2 (K10 §4.2,
 *     k10-client-protocol-v0.md:208-214; adapter.py:78, :152-161).  It is sent on BOTH `open` and
 *     `neighbours` (i2_binding.py:492-498, :546-547; routes.py:145, :164) and on NEITHER is it
 *     forwarded to the store (adapter.py:156-157) — a deck-internal mapping fact that does not
 *     license omitting it from the request.  I3-10 `lookup` has no `distance` input at all.
 *   * When no bucket is named, the chosen bucket is the FIRST of
 *     `open.buckets.map(b => b['link-type'])` — the store emits buckets sorted by UTF-8 order of
 *     the link type (i2_read.py:891), so "first" is that order and not a client preference
 *     (i2_binding.py:542-544).
 *   * A card with NO buckets yields `bucket: null` and `neighbours: null` — "reported as None
 *     rather than invented" (i2_binding.py:507, :542-544).
 *   * NOTHING IS DERIVED TWICE.  The digest is the store's own at every step and is never
 *     computed here (adapter.py:1473-1476; i2_binding.py:177-197).  `read-at` is whatever each
 *     step measured and is never copied between steps.
 *
 * THE ONE DELIBERATE DIFFERENCE, and it is a difference of TRANSPORT, not of behaviour: the
 * step-1 early-return branch in Python has FOUR keys and omits `bucket` entirely
 * (i2_binding.py:530-531).  This mirror always returns the same FIVE keys with `bucket: null`,
 * because a JS caller reading `path.bucket` on the four-key shape would silently get `undefined`
 * where the contract means "no bucket was chosen".  The key is present and explicitly null
 * instead.  Both shapes carry the same information; this one cannot be misread.
 *
 * @param {object} transport  from createLiveTransport
 * @param {string} name       a bare card name
 * @param {{distance?: number|string|null, bucket?: string|null}} [options]
 * @returns {Promise<{mode: string, lookup: object|null, open: object|null, bucket: string|null, neighbours: object|null}>}
 */
export async function realCardPath(transport, name, { distance = '0', bucket = null } = {}) {
  if (!transport || typeof transport.lookup !== 'function') {
    throw new LiveConfigurationUnresolved('realCardPath needs a transport from createLiveTransport');
  }
  // VALIDATED BEFORE ANY USE: one well-formed value, carried UNSATURATED to every step that takes
  // one.  The deck saturates; this client does not (K10 §4.2).
  const validated = validateDistance(distance);
  const lookup = await transport.lookup({ name });
  if (!lookup || lookup.outcome !== 'ok') {
    return { mode: MODE, lookup, open: null, bucket: null, neighbours: null };
  }
  if (typeof lookup.key !== 'string' || lookup.key === '') {
    throw new LiveProtocolViolation(
      'I3-10 lookup answered "ok" without a key; the client never invents one',
      { endpointId: 'I3-10' },
    );
  }
  const address = { kind: 'key', text: lookup.key };
  const opened = await transport.open({ participant: address, distance: validated });

  if (!opened || !PAYLOAD_OUTCOMES.includes(opened.outcome)) {
    // Step 2 returned no participant, so there is no bucket of it to ask about.  Step 2's own
    // answer is preserved exactly and the absence of step 3 is REPORTED, never invented
    // (i2_binding.py:537-541).  An explicitly named `bucket` does not bypass this.
    return { mode: MODE, lookup, open: opened, bucket: null, neighbours: null };
  }

  let chosen = bucket;
  let neighbours = null;
  if (chosen === null || chosen === undefined) {
    const buckets = Array.isArray(opened.buckets)
      ? opened.buckets.map((b) => b['link-type'])
      : [];
    chosen = buckets.length > 0 ? buckets[0] : null;
  }
  if (chosen !== null && chosen !== undefined) {
    neighbours = await transport.neighbours({ participant: address, bucket: chosen, distance: validated });
  }
  return { mode: MODE, lookup, open: opened, bucket: chosen, neighbours };
}

// ---------------------------------------------------------------- scene-producing entry points

/**
 * LIVE equivalent of fixture-bridge.mjs `openScene`.
 *
 * Returns the SAME SIX KEYS the fixture path returns — `{ graph, result, file, recording,
 * response, scene }` — so index.html's pipeline is transport-agnostic and the renderer and layout
 * see a scene built by the identical `sceneFrom`.  Two of those keys say honest things about a
 * live read rather than pretending to be a recording:
 *
 *   * `file` is null.  A live read has no fixture filename, and a filename is not invented.
 *   * `recording` is null.  There is NO RECORDING.  fixture-bridge's `recording` is fixture
 *     METADATA; a live read has none, and manufacturing a recording block would be exactly the
 *     fabrication this bridge exists to avoid.
 *
 * `mode` and `request` are ADDED, not substituted: `mode` is the single live literal, and
 * `request` reports the real URL that was really fetched, so evidence can name it.
 *
 * An `open` is a WHOLE read, so it starts a FRESH graph rather than merging — the same rule
 * fixture-bridge.mjs:233-235 states.
 */
export async function openSceneLive(transport, { participant, distance = null, focus = null, kind = null, cardType = null, direction = null, budget = null }) {
  const pairs = openPairs({ participant, distance, focus, kind, cardType, direction, budget });
  const url = transport.urlFor(I3_ENDPOINTS.open, pairs);
  const response = await transport.open({ participant, distance, focus, kind, cardType, direction, budget });
  const graph = emptyDrawnGraph();
  const result = ingestOpen(response, graph);
  return {
    graph,
    result,
    file: null,
    recording: null,
    response,
    scene: sceneFrom(graph, result),
    mode: MODE,
    request: { endpointId: I3_ENDPOINTS.open.id, url },
  };
}

/**
 * LIVE equivalent of fixture-bridge.mjs `ingestPageInto`.
 *
 * Returns `{ graph, result, scene }` exactly as the fixture path does, plus `mode` and `request`.
 * The whole scene is RE-READ after the merge because a page can raise the arity of an
 * already-drawn link and turn a line into a link node (fixture-bridge.mjs:254-265).
 *
 * `result.cursorStale` is surfaced untouched.  A stale cursor is REPORTED, never silently healed:
 * the paging policy is the caller's, and this module makes no paging decision.
 */
export async function ingestNeighboursPageLive(transport, graph, { participant, bucket, after = null, distance = null, kind = null, cardType = null, direction = null }) {
  if (!graph) {
    throw new TypeError('ingestNeighboursPageLive merges into an existing graph; pass one');
  }
  const pairs = neighboursPairs({ participant, bucket, after, distance, kind, cardType, direction });
  const url = transport.urlFor(I3_ENDPOINTS.neighbours, pairs);
  const response = await transport.neighbours({ participant, bucket, after, distance, kind, cardType, direction });
  const result = ingestNeighboursPage(response, graph);
  return {
    graph,
    result,
    scene: sceneFrom(graph, result),
    mode: MODE,
    request: { endpointId: I3_ENDPOINTS.neighbours.id, url },
  };
}

/**
 * Turn any bridge failure into PLAIN TEXT lines for a text-only sink.
 *
 * ALL TEXT, NO MARKUP.  Every value is a plain string destined for `textContent` (the status strip
 * takes exactly this `[key, value]` pair shape — index.html:234-244).  Nothing here builds a DOM
 * node, returns HTML, or interpolates a backend string into a markup context.  A backend-supplied
 * body is surfaced only as the already-bounded, whitespace-flattened `bodySnippet`.
 *
 * The CLASSIFICATION is reported as itself so a refusal is never shown as a generic error and a
 * missing route is never shown as an auth failure.
 *
 * @returns {Array<[string, string]>}
 */
export function refusalLines(err) {
  if (!err) return [['error', 'an unreported failure']];
  const lines = [['live', 'REFUSED — nothing is drawn']];
  lines.push(['reason', String(err.message ?? err)]);
  if (err.endpointId) lines.push(['step', String(err.endpointId)]);
  if (err instanceof LiveTransportFailed) {
    lines.push(['classification', String(err.classification)]);
    if (err.status !== null && err.status !== 0) lines.push(['http', String(err.status)]);
    if (err.url) lines.push(['url', String(err.url)]);
    if (err.contentType) lines.push(['content-type', String(err.contentType)]);
    if (err.bodySnippet) lines.push(['body', String(err.bodySnippet)]);
  } else if (err instanceof LiveProtocolViolation) {
    lines.push(['classification', 'protocol-violation']);
  } else if (err instanceof LiveConfigurationUnresolved) {
    lines.push(['classification', 'configuration-unresolved']);
  } else if (err instanceof LiveMalformedInput) {
    lines.push(['classification', 'malformed-input']);
  }
  lines.push(['fallback', 'none — a live request is never answered from a recording']);
  return lines;
}
