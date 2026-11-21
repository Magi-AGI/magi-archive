// ================================================================================================
// EXPLICIT DEMO MODE SELECTION  —  src/demo/demo-mode.mjs
// ================================================================================================
//
// WHY THIS EXISTS.  Before this module there was NO mode selection of any kind: the fixture base
// was a module constant (fixture-bridge.mjs:51) and the startup scene was a hardcoded
// `demoScenes()[0].file` (index.html:665).  A live transport cannot be bolted onto that without a
// deliberate, VISIBLE choice, because the one thing that must never happen is a live read quietly
// being answered from the recorded corpus.
//
// THE RULE THIS MODULE ENFORCES.  Mode is EXPLICIT and ONE-WAY:
//
//   * `?mode=fixture` (and, for compatibility, NO parameter at all) selects the RECORDED path.
//     That preserves the existing E1 regression exactly: verify.html and index.html with a bare
//     URL behave byte-for-byte as before, because this module returns the same fixture base that
//     was already hardcoded.
//   * `?mode=live` selects the LIVE path and REQUIRES an explicit `?backend=` origin.  There is
//     no default origin, no auto-discovery, and no "try live, fall back to fixtures".  If live is
//     asked for and cannot be configured, the answer is a REFUSAL carrying the reason — never a
//     recording.  (The same fail-closed stance as i2_binding.py:36-48, :221-226.)
//   * Any other `mode=` value is REFUSED by name rather than coerced to a default.
//
// ONE-WAY means: once `mode === 'live'`, nothing in this module or in live-bridge.mjs can produce
// a fixture response.  live-bridge.mjs imports no fixture loader and reads no recorded file; the
// only thing it shares with the fixture path is `sceneFrom`, which is pure derivation over an
// already-ingested graph and carries no substance of its own.
//
// NO CREDENTIALS IN THE URL.  `backend` is an ORIGIN only: scheme + host + port, no path, no
// query, no userinfo, no fragment.  A URL carrying `user:password@` is refused outright, and no
// token-shaped parameter is read from the query string at all.  A browser query string is a
// terrible place for a secret — it lands in history, in referrers and in server logs — so this
// module declines to accept one anywhere.
//
// ================================================================================================

import { FIXTURE_BASE_DEFAULT } from './fixture-bridge.mjs';

/** The two modes.  There is no third, and no implicit one. */
export const MODES = Object.freeze({ fixture: 'fixture', live: 'live' });

/**
 * The mode used when the URL names none.
 *
 * It is FIXTURE, and that is a compatibility decision, not a preference: every existing entry
 * point (index.html opened bare, verify.html, the E1 evidence runs) carries no query string and
 * must keep working unchanged.  The important half of the no-silent-fallback rule is the other
 * direction: an EXPLICIT live request never degrades into this.
 */
export const DEFAULT_MODE = MODES.fixture;

/** Raised when the URL asks for something this module will not resolve.  Text-only message. */
export class DemoModeUnresolved extends Error {
  constructor(message, { mode = null, detail = null } = {}) {
    super(message);
    this.name = 'DemoModeUnresolved';
    this.mode = mode;
    this.detail = detail;
  }
}

function originOf(raw) {
  let parsed;
  try {
    parsed = new URL(raw);
  } catch {
    throw new DemoModeUnresolved(
      `backend must be an absolute origin such as http://127.0.0.1:9292 — got ${raw}`,
      { mode: MODES.live, detail: 'not-a-url' },
    );
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    throw new DemoModeUnresolved(
      `backend origin must be http or https; got ${parsed.protocol}`,
      { mode: MODES.live, detail: 'bad-scheme' },
    );
  }
  if (parsed.username !== '' || parsed.password !== '') {
    throw new DemoModeUnresolved(
      'backend origin must not carry credentials. A URL is not a place for a secret.',
      { mode: MODES.live, detail: 'credentials-in-url' },
    );
  }
  if ((parsed.pathname !== '/' && parsed.pathname !== '') || parsed.search !== '' || parsed.hash !== '') {
    throw new DemoModeUnresolved(
      `backend must be an ORIGIN with no path, query or fragment; got ${raw}`,
      { mode: MODES.live, detail: 'not-an-origin' },
    );
  }
  return parsed;
}

const LOOPBACK_HOSTS = Object.freeze(['127.0.0.1', 'localhost', '[::1]', '::1']);

/** Is this hostname a loopback host?  Exported so the UI can say so without re-parsing. */
export function isLoopbackHost(hostname) {
  return LOOPBACK_HOSTS.includes(hostname);
}

/**
 * The credential branch names accepted in the URL, mapped to live-bridge's `credentialMode`.
 *
 * `?credentials=none` (the DEFAULT when the parameter is absent) is the credential-less branch.
 * `?credentials=decko-session` asks the browser to reuse the Decko session cookie it ALREADY
 * HOLDS, which is permitted ONLY against a same-origin backend.
 *
 * This is a CLOSED ENUM read from an explicit parameter.  It is deliberately NOT inferred from
 * `backend` being empty: "the backend string is empty" and "this request goes to my own origin"
 * are different claims, and only the second one may license a cookie.  A page served from a
 * non-loopback origin may legitimately name its own origin explicitly, and an endpoint could
 * resolve off-origin even from an empty base, so the branch is stated and then the RESOLVED
 * origin of every request is checked by live-bridge.mjs.
 */
export const CREDENTIAL_SELECTIONS = Object.freeze({
  none: 'none',
  'decko-session': 'decko-session',
});

/** The branch used when the URL names none: credential-less. */
export const DEFAULT_CREDENTIAL_SELECTION = 'none';


/**
 * Resolve the demo mode from a query string.
 *
 * PURE AND INJECTED: it takes the search string, not `location`, so it is unit-testable and so the
 * page reads the URL exactly once, at startup, in one place.
 *
 * Recognised parameters:
 *   `mode`     'fixture' | 'live'.  Absent -> DEFAULT_MODE.
 *   `backend`  REQUIRED when mode=live.  An absolute http(s) ORIGIN, no path/query/fragment/userinfo.
 *              The empty string is accepted and means "this page's own origin" (the same-origin
 *              case, which needs no CORS).
 *   `card`     optional, the bare card NAME to look up first in live mode.  Carried through
 *              verbatim — not trimmed, not normalised, not case-folded.
 *   `distance` optional, forwarded VERBATIM to I3-02 `open` and I3-03 `neighbours`.  NOT
 *              normalised here and NOT clamped: the client validates the FORMAT only (a
 *              non-negative decimal integer; anything else is refused on the refusal path) and
 *              sends the value unclamped.  The DECK saturates at 2 (K10 §4.2 — the client does
 *              not pre-clamp and does not re-own the rule).
 *   `bucket`   optional, pins the link type for I3-03 `neighbours` instead of taking the first
 *              bucket the open reported.
 *   `credentials` optional, 'none' (default) or 'decko-session'.  'decko-session' permits the
 *              browser's EXISTING Decko session cookie on requests to a SAME-ORIGIN backend and
 *              is refused against any other origin, with no credential-less retry.  Any other
 *              value is refused by name.  No token-shaped value is read from the URL in either
 *              branch, and no Authorization header is ever sent.
 *   `allow-non-loopback`  must be the exact string '1' to permit a non-loopback backend origin.
 *              Default is to REFUSE one, because the local demo server sends no CORS headers and
 *              refuses OPTIONS with 405 (server.py:268), so a cross-origin read cannot work by
 *              accident — it has to be arranged, and saying so is better than a mystery failure.
 *
 * @param {string} search  e.g. location.search
 * @returns {Readonly<object>} frozen; `mode` is always one of MODES
 */
export function resolveDemoMode(search) {
  const params = new URLSearchParams(typeof search === 'string' ? search : '');
  const raw = params.get('mode');

  if (raw === null || raw === '') {
    return Object.freeze({
      mode: MODES.fixture,
      explicit: false,
      fixtureBase: FIXTURE_BASE_DEFAULT,
      backendOrigin: null,
      allowNonLoopback: false,
      credentialMode: DEFAULT_CREDENTIAL_SELECTION,
      card: null,
      distance: null,
      bucket: null,
      banner:
        'FIXTURE MODE (default, no ?mode= given). Every response is a RECORDED fixture from the '
        + 'lane-F corpus. Nothing is read from any backend.',
    });
  }

  if (raw === MODES.fixture) {
    return Object.freeze({
      mode: MODES.fixture,
      explicit: true,
      fixtureBase: FIXTURE_BASE_DEFAULT,
      backendOrigin: null,
      allowNonLoopback: false,
      credentialMode: DEFAULT_CREDENTIAL_SELECTION,
      card: null,
      distance: null,
      bucket: null,
      banner:
        'FIXTURE MODE (explicitly selected). Every response is a RECORDED fixture from the '
        + 'lane-F corpus. Nothing is read from any backend.',
    });
  }

  if (raw === MODES.live) {
    if (!params.has('backend')) {
      throw new DemoModeUnresolved(
        'mode=live needs an explicit ?backend= origin. There is no default backend and no '
        + 'auto-discovery, and a live request is never answered from the recorded corpus. '
        + "Use ?backend= (empty) for this page's own origin, or ?backend=http://127.0.0.1:PORT.",
        { mode: MODES.live, detail: 'backend-absent' },
      );
    }
    const backendRaw = params.get('backend');
    const allowNonLoopback = params.get('allow-non-loopback') === '1';

    // The credential branch: an EXPLICIT closed-enum choice, defaulted to credential-less and
    // never inferred from whether `backend` happens to be empty.
    const credentialRaw = params.has('credentials') ? params.get('credentials') : null;
    let credentialMode = DEFAULT_CREDENTIAL_SELECTION;
    if (credentialRaw !== null && credentialRaw !== '') {
      if (!Object.prototype.hasOwnProperty.call(CREDENTIAL_SELECTIONS, credentialRaw)) {
        throw new DemoModeUnresolved(
          `unknown credentials "${credentialRaw}". The only branches are "none" (send no cookie `
          + 'and no auth state) and "decko-session" (reuse the browser\'s existing Decko session '
          + 'cookie, same-origin only). Neither is guessed, and no token is read from the URL.',
          { mode: MODES.live, detail: 'unknown-credentials' },
        );
      }
      credentialMode = CREDENTIAL_SELECTIONS[credentialRaw];
    }
    const sessionBranch = credentialMode === CREDENTIAL_SELECTIONS['decko-session'];

    let backendOrigin = '';
    let where = "this page's own origin (same-origin; no CORS needed)";
    if (backendRaw !== '') {
      const parsed = originOf(backendRaw);
      if (!isLoopbackHost(parsed.hostname) && !allowNonLoopback) {
        throw new DemoModeUnresolved(
          `backend ${parsed.origin} is not a loopback origin. The local demo server sends no CORS `
          + 'headers and refuses OPTIONS, so a cross-origin read cannot succeed by accident. Add '
          + '&allow-non-loopback=1 to say you have arranged it deliberately.',
          { mode: MODES.live, detail: 'non-loopback-origin' },
        );
      }
      backendOrigin = parsed.origin;
      where = parsed.origin;
    }
    const card = params.has('card') ? params.get('card') : null;
    if (card !== null && card === '') {
      throw new DemoModeUnresolved(
        'card: empty name. I3-10 lookup refuses an empty name; nothing is substituted for it.',
        { mode: MODES.live, detail: 'empty-card' },
      );
    }
    // The page's own origin is NOT known to this pure function, so a selected non-empty backend
    // cannot be compared against it here.  That comparison belongs to the caller, which has
    // `location.origin`, and to live-bridge.mjs, which checks the RESOLVED origin of every
    // request before sending.  Nothing is assumed same-origin on this layer's behalf.
    const credentialNote = sessionBranch
      ? 'CREDENTIALS: decko-session. The browser is permitted to attach the Decko session cookie '
        + 'it ALREADY HOLDS for this origin, and only to a SAME-ORIGIN backend. No token is read '
        + 'from the URL and no Authorization header is sent. Every request\'s resolved origin is '
        + "checked against this page's origin before it is sent; an off-origin request is REFUSED "
        + 'and is NOT retried without the cookie.'
      : 'CREDENTIALS: none. No cookie, no HTTP-auth state, no token and no Authorization header '
        + 'is sent, even if the browser holds one for that origin.';
    return Object.freeze({
      mode: MODES.live,
      explicit: true,
      fixtureBase: null,
      backendOrigin,
      allowNonLoopback,
      credentialMode,
      card,
      distance: params.has('distance') ? params.get('distance') : null,
      bucket: params.has('bucket') ? params.get('bucket') : null,
      banner:
        `LIVE MODE. Every response is fetched from ${where} over the I3 surface `
        + '(lookup -> open -> neighbours). NO fixture is read and no recorded response can be '
        + 'shown in this mode: if the backend refuses or is not ready, the page says so and '
        + `draws nothing. ${credentialNote}`,
    });
  }

  throw new DemoModeUnresolved(
    `unknown mode "${raw}". The only modes are "fixture" and "live"; neither is guessed.`,
    { mode: null, detail: 'unknown-mode' },
  );
}
