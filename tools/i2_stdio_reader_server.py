#!/usr/bin/env python3
"""The LOCAL STDIO server that puts VIEW's Ruby I3 reader in front of STORE's REAL I2Reader.

WHAT THIS IS. One process, started EXPLICITLY by a local operator, that reads one line of JSON per
request on stdin and writes one line of JSON per response on stdout. Behind it is STORE's genuine
``atomspace_mirror_sidecar.i2_read.I2Reader`` over a genuine ``record_store.RecordStore`` --
constructed canonically as STORE specified (handoff 022b Q11):

    I2Reader(RecordStore(retention=RetentionWindow(...)), I2Config(...))

WHAT IT IS NOT, and every one of these is a hard boundary:

* **NOT a fake, mock, stub or test reader.** It imports STORE's module and constructs STORE's
  classes. ``--self-check`` refuses to run if the loaded ``I2Reader`` is not the real class.
* **NOT a socket, a URL or a service.** It binds no port and opens no listener. STORE's own
  header: the I2 slice is "Not exposed on any socket: privileged, identity-free, and not MCP REST"
  (``i2_read.py:57-58``). STDIO is the only channel, and it exists only as a child of whoever
  started it.
* **NOT authenticated, and it carries NO IDENTITY.** STORE handoff 022b Q12 is CONFIRMED: no user
  identity at the I2 call; the ACL stays on VIEW's I3 side. A request frame has no field for a
  principal and this server would refuse one as an unexpected key.
* **NOT a deployment and NOT autoloaded.** Nothing imports this module as a side effect. It runs
  only when a human runs it, with an explicit interpreter and an explicit sidecar path.
* **NOT a producer.** It publishes nothing by itself. A store with no published state answers
  ``not ready`` with three nulls, which is the correct answer and the one VIEW's client expects.
  There is NO v2 producer deployed and nothing on Magi DEV feeds a record store today
  (handoff 022b).

CONFIGURATION IS EXPLICIT AND HAS NO DEFAULTS. ``I2Config`` itself has none ("Every value is
required; there is no default anywhere" -- ``i2_read.py:120``), so neither does this: the six
ceilings and the two retention bounds arrive in ``AV_I2_STDIO_CONFIG`` as JSON, and a missing one
is ``UnresolvedConfiguration``, reported as an error frame -- never a guess.

FAIL CLOSED. Every exception becomes an ``ok: false`` error frame with a ``kind`` VIEW maps to a
distinct reason. No operation ever answers with a synthesised envelope: the four envelope fields
come from STORE's own ``_envelope`` / ``no_state_envelope`` and are copied, not constructed.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import sys
import types

PROTOCOL_VERSION = 1

#: The documented env var naming STORE's worktree root (the dir CONTAINING
#: ``atomspace_mirror_sidecar/``). Same contract as ``i2_binding.py``'s SIDECAR_PATH_ENV: no
#: auto-discovery, no default, an unset path is an error.
SIDECAR_PATH_ENV = "AV_STORE_SIDECAR_PATH"
CONFIG_ENV = "AV_I2_STDIO_CONFIG"

#: The four envelope keys STORE emits (``i2_read.py:515-518``; ``record_store.py:196-201``). The
#: server SPLITS a reader result into envelope + payload on exactly these keys and never invents
#: one: a result missing any of them is an error frame, not a patched envelope.
ENVELOPE_KEYS = ("outcome", "epoch", "position", "read-at")


class ServerRefused(Exception):
    """A request this server will not answer. Carries the kind VIEW maps to a reason."""

    def __init__(self, kind, reason):
        self.kind, self.reason = kind, reason
        super().__init__(f"{kind}: {reason}")


def load_sidecar(sidecar_path):
    """Import STORE's modules from an EXPLICIT path. No search, no default, no install.

    Mirrors ``i2_binding.py``'s loader: the path names the directory that CONTAINS
    ``atomspace_mirror_sidecar/``, and an absent module is a named error rather than a fallback.
    """
    if not sidecar_path:
        raise ServerRefused("unresolved-config",
                            f"{SIDECAR_PATH_ENV} is unset; there is no default and no discovery")
    pkg_dir = os.path.join(sidecar_path, "atomspace_mirror_sidecar")
    if not os.path.isdir(pkg_dir):
        raise ServerRefused("unresolved-config",
                            f"no atomspace_mirror_sidecar/ under {sidecar_path!r}")

    # A real package import, so STORE's own relative imports (``from .record_store import ...``)
    # resolve exactly as they do in its test suite.
    if sidecar_path not in sys.path:
        sys.path.insert(0, sidecar_path)
    import atomspace_mirror_sidecar.i2_read as i2_read            # noqa: E402
    import atomspace_mirror_sidecar.record_store as record_store  # noqa: E402
    return i2_read, record_store


def build_reader(i2_read, record_store, config):
    """The CANONICAL construction, exactly as STORE specified (handoff 022b Q11).

    ``I2Reader(RecordStore(retention=RetentionWindow(...)), I2Config(...))``. Both STORE classes,
    both STORE's own validation. Every value comes from ``config``; none is defaulted here.
    """
    if not isinstance(config, dict):
        raise ServerRefused("unresolved-config", "the configuration must be a JSON object")

    retention = config.get("retention")
    if not isinstance(retention, dict) or set(retention) != {"positions", "ms"}:
        raise ServerRefused("unresolved-config",
                            "retention must be exactly {'positions', 'ms'} (either may be null); "
                            "P-STATE-RETAIN has no default (record_store.py:206-209)")

    # STORE's own constructors raise UnresolvedConfiguration / ValueError / TypeError on anything
    # missing or malformed, and those propagate as error frames. Nothing is pre-filled.
    window = record_store.RetentionWindow(positions=retention["positions"], ms=retention["ms"])
    store = record_store.RecordStore(retention=window)
    i2_config = i2_read.I2Config.from_mapping(config)
    reader = i2_read.I2Reader(store, i2_config)

    # ANTI-FAKE ASSERTION. If anything other than STORE's real classes is in play, refuse: a
    # server that silently served a double would make every downstream proof worthless.
    if type(reader) is not i2_read.I2Reader or type(store) is not record_store.RecordStore:
        raise ServerRefused("server-error", "the constructed reader is not STORE's own I2Reader")
    return reader, store


def split_envelope(result):
    """Split one reader result into (envelope, payload) on STORE's four keys.

    THE ENVELOPE IS COPIED, NEVER CONSTRUCTED. A result missing any of the four is refused, so a
    malformed reader answer can never reach VIEW wearing a complete-looking envelope. This is the
    server-side half of the same fail-closed rule VIEW's ``I2Envelope`` enforces on arrival --
    checked twice on purpose, because each side must be safe alone.
    """
    if not isinstance(result, dict):
        raise ServerRefused("server-error", f"a reader result is a mapping, got {type(result).__name__}")
    missing = [k for k in ENVELOPE_KEYS if k not in result]
    if missing:
        raise ServerRefused("server-error",
                            f"the reader result is missing envelope field(s) {missing}; no value is "
                            f"substituted")
    envelope = {k: result[k] for k in ENVELOPE_KEYS}
    payload = {k: v for k, v in result.items() if k not in ENVELOPE_KEYS}
    return envelope, payload


def dispatch(reader, op, args):
    """One I2 operation. The op->method map is STORE's own (``i2_read.py`` section comments).

    I2-01 status | I2-02 buckets | I2-03 neighbours | I2-07 declarations | I2-09 open ANSWER.
    I2-04/05/06/08/10 are refused BY STORE'S OWN CODE (``i2_read.py:898-911``) -- this server does
    not pre-empt them with its own refusal, it CALLS them, so the refusal that reaches VIEW is the
    store's real one.
    """
    if not isinstance(args, dict):
        raise ServerRefused("i2-refused", "args must be a mapping")

    if op == "I2-01":
        return reader.status()
    if op == "I2-07":
        return reader.declarations()
    if op == "I2-02":
        return reader.buckets(args.get("participant"))
    if op == "I2-03":
        # NARROWING IS PASSED THROUGH, NOT DROPPED. VIEW's client never sends one (it is
        # unsupported -- handoff 022b §3), but if a narrowing DOES arrive this server must not
        # silently discard it: STORE is explicit that a non-empty narrowing "is never ignored and
        # never reported via omitted" and raises I2Refused BEFORE readiness
        # (``i2_read.py:681-684`` ``_no_narrowing``). Dropping it here would manufacture a success
        # for a request the slice refuses, which is the exact failure mode this lane forbids.
        return reader.neighbours(args.get("participant"), args.get("bucket"),
                                 narrowing=args.get("narrowing"),
                                 after=args.get("after"), limits=args.get("limits"))
    if op == "I2-09":
        return reader.open(args.get("participant"), focus_request=args.get("focus_request"),
                           narrowing=args.get("narrowing"), limits=args.get("limits"))
    if op in ("I2-04", "I2-05", "I2-06", "I2-08", "I2-10"):
        # Call STORE's own refusing method so VIEW sees the store's real I2Refused text.
        return {"I2-04": lambda: reader.atoms_of(args.get("participant")),
                "I2-05": lambda: reader.atom(args.get("address")),
                "I2-06": lambda: reader.unattached(),
                "I2-08": lambda: reader.changes_since(args.get("epoch"), args.get("position")),
                "I2-10": lambda: reader.refresh(args.get("participants"), args.get("extents"),
                                                args.get("since_position"))}[op]()
    raise ServerRefused("i2-refused", f"unknown operation {op!r}")


# Key names that would carry a PRINCIPAL. The I2 call has no identity (STORE handoff 022b Q12),
# so none of these may appear in a request AT ANY DEPTH. Mirrors VIEW's own
# ``I2StdioTransport::FORBIDDEN_IDENTITY_KEYS`` -- deliberately duplicated rather than shared,
# because each side must be independently identity-free.
#
# ``authtoken`` is listed EXPLICITLY, mirroring VIEW's own entry. ``_normalise_identity_key``
# maps ``auth_token``/``Auth-Token`` to ``authtoken`` and membership is tested against that
# NORMALISED form, so the alias the docstring below advertises was the one alias not actually
# rejected until this entry existed: ``auth`` and ``token`` are separate whole-key entries and
# this check is never a substring match.
FORBIDDEN_IDENTITY_KEYS = frozenset({
    "account", "token", "bearer", "cookie", "user", "principal", "session", "authorization",
    "auth", "authtoken", "credential", "password", "secret", "apikey", "xapikey", "accesstoken",
    "refreshtoken", "identity", "actor", "subject", "login", "username", "userid",
    "accountid", "accountname", "sessionid", "sessiontoken", "csrftoken", "jwt", "oauth",
    "privatekey", "signingkey", "signature", "assertion", "samlresponse", "idtoken",
    "clientsecret",
})


def _normalise_identity_key(key):
    """Lowercase and strip separators so ``X-API-KEY``/``auth_token`` are caught, not just exact spellings."""
    return "".join(ch for ch in str(key).lower() if ch not in "-_ \t")


def _reject_identity_keys(value, path="args"):
    """Walk args and refuse any identity-shaped key at ANY depth. Lists are descended too."""
    if isinstance(value, dict):
        for key, sub in value.items():
            if _normalise_identity_key(key) in FORBIDDEN_IDENTITY_KEYS:
                raise ServerRefused(
                    "i2-refused",
                    f"request args carry a forbidden identity-shaped key at {path}.{key}",
                )
            _reject_identity_keys(sub, f"{path}.{key}")
    elif isinstance(value, (list, tuple)):
        for index, sub in enumerate(value):
            _reject_identity_keys(sub, f"{path}[{index}]")
    return value


def handle(reader, i2_read, frame):
    """One request frame -> one response frame. Never raises; every failure is an error frame."""
    fid = frame.get("id") if isinstance(frame, dict) else None
    try:
        if not isinstance(frame, dict):
            raise ServerRefused("i2-refused", "a request frame is a JSON object")
        extra = set(frame) - {"v", "id", "op", "args", "deadline-ms"}
        if extra:
            # An UNEXPECTED KEY IS REFUSED, which is what keeps an identity field from ever being
            # honoured: there is no 'account'/'token'/'user' slot, and smuggling one fails loudly.
            raise ServerRefused("i2-refused", f"unexpected request keys {sorted(extra)}")
        # AND NO IDENTITY NESTED INSIDE ``args`` EITHER. The check above is top-level only, while
        # ``args`` is an unrestricted mapping by design, so a nested
        # ``args={"participant": {"token": ...}}`` would otherwise pass. VIEW's client refuses the
        # same shape before writing (i2_stdio_transport.rb FORBIDDEN_IDENTITY_KEYS); this server
        # refuses it independently, because a server that trusts its client to sanitise is not
        # itself identity-free.
        _reject_identity_keys(frame.get("args", {}))
        if frame.get("v") != PROTOCOL_VERSION:
            raise ServerRefused("i2-refused", f"protocol {frame.get('v')!r} is not {PROTOCOL_VERSION}")
        if not isinstance(fid, str) or not fid:
            raise ServerRefused("i2-refused", "id must be a non-empty string")

        result = dispatch(reader, frame.get("op"), frame.get("args", {}))
        envelope, payload = split_envelope(result)
        return {"v": PROTOCOL_VERSION, "id": fid, "ok": True,
                "envelope": envelope, "payload": payload}

    except ServerRefused as exc:
        return _error(fid, exc.kind, exc.reason)
    except i2_read.I2Refused as exc:
        # STORE's OWN refusal, propagated with its own operation and reason text UNCHANGED.
        return _error(fid, "i2-refused", f"{exc.operation}: {exc.reason}")
    except i2_read.UnresolvedConfiguration as exc:
        return _error(fid, "unresolved-config", "; ".join(exc.problems))
    except KeyError as exc:
        # The ``runtime`` KeyError STORE named (handoff 022b §2) lands here. Reported as
        # capability-missing with NO value invented -- never a fabricated version string.
        return _error(fid, "capability-missing", f"no source for {exc.args[0]!r}")
    except Exception as exc:                                       # noqa: BLE001
        return _error(fid, "server-error", f"{type(exc).__name__}: {exc}")


def _error(fid, kind, reason):
    return {"v": PROTOCOL_VERSION, "id": fid if isinstance(fid, str) else "",
            "ok": False, "error": {"kind": kind, "reason": reason}}


def serve(reader, i2_read, stdin, stdout):
    """The loop: one line in, one line out. EOF on stdin ends it cleanly."""
    for line in stdin:
        line = line.strip()
        if not line:
            continue
        try:
            frame = json.loads(line)
        except json.JSONDecodeError as exc:
            frame = None
            response = _error("", "i2-refused", f"not JSON: {exc}")
        else:
            response = handle(reader, i2_read, frame)
        stdout.write(json.dumps(response, ensure_ascii=False) + "\n")
        stdout.flush()


def seed_from_golden_vectors(sidecar_path, record_store, store, names):
    """OPERATOR-ONLY, EXPLICITLY LABELLED: publish a first state from STORE's own GOLDEN VECTORS.

    WHAT THIS DATA IS, stated so it cannot be mistaken for anything else. STORE sanctioned exactly
    this local use (handoff 022b, "USING REAL-SHAPED v2 DATA LOCALLY"): ``encode_card_state`` over
    the shared golden vectors, published through ``BootstrapRun``. STORE's own words, which this
    docstring repeats rather than softens:

        "The inputs are V1-shaped, e.g. the shared golden vectors. They are NOT DEV data."
        "Nothing on Magi DEV feeds a record store today: there is no producer."

    So a reader seeded this way serves REAL-SHAPED v2 atoms produced by STORE's REAL encoder and
    admitted by STORE's REAL bootstrap validator -- and NOT live Decko data. It exists so the five
    answering operations can be exercised end to end at all; it establishes no producer, no
    deployment and no DEV read.

    It is OFF unless the operator passes ``--seed-from-golden-vectors``. A served store is never
    seeded implicitly, because a fabricated-looking state appearing by default is precisely the
    failure this whole lane is built to prevent.
    """
    import json as _json

    v2 = importlib.import_module("atomspace_mirror_sidecar.v2_bootstrap")
    fixture = os.path.join(sidecar_path, "tests", "fixtures", "golden_projection_vectors.json")
    if not os.path.isfile(fixture):
        raise ServerRefused("unresolved-config", f"no golden vectors at {fixture!r}")
    with open(fixture, encoding="utf-8") as handle:
        raw = _json.load(handle)["vectors"]
    # The fixture's shape is STORE's own: a LIST of {"name", "input"} records, keyed exactly as
    # STORE's suite keys it (tests/test_v2_bootstrap.py:24
    # `{v["name"]: v["input"] for v in ...["vectors"]}`). Read the same way here so the vector
    # names an operator passes are the names STORE uses.
    vectors = {v["name"]: v["input"] for v in raw}

    missing = [n for n in names if n not in vectors]
    if missing:
        raise ServerRefused("unresolved-config",
                            f"unknown golden vector(s) {missing}; available: {sorted(vectors)}")

    run = v2.BootstrapRun(store, "view-lane-d-local-exercise")
    run.add_batch(0, v2.DECLARATIONS)
    report = run.add_batch(1, [v2.encode_card_state(vectors[n]) for n in names], final=True)
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-check", action="store_true",
                        help="construct the real reader, prove it is STORE's own class, and exit")
    parser.add_argument("--seed-from-golden-vectors", metavar="NAME", action="append", default=None,
                        help="OPERATOR-ONLY: publish a first state from STORE's V1-shaped golden "
                             "vectors via STORE's own encoder + BootstrapRun. NOT DEV data, NOT a "
                             "producer, NOT a deployment. Off unless passed explicitly.")
    opts = parser.parse_args(argv)

    raw = os.environ.get(CONFIG_ENV)
    if not raw:
        sys.stderr.write(f"{CONFIG_ENV} is unset; the I2 ceilings have no defaults\n")
        return 2
    try:
        config = json.loads(raw)
    except json.JSONDecodeError as exc:
        sys.stderr.write(f"{CONFIG_ENV} is not JSON: {exc}\n")
        return 2

    try:
        i2_read, record_store = load_sidecar(os.environ.get(SIDECAR_PATH_ENV))
        reader, store = build_reader(i2_read, record_store, config)
    except ServerRefused as exc:
        sys.stderr.write(f"{exc}\n")
        return 2
    except Exception as exc:                                       # noqa: BLE001
        sys.stderr.write(f"{type(exc).__name__}: {exc}\n")
        return 2

    if opts.self_check:
        sys.stdout.write(json.dumps({
            "reader_class": f"{type(reader).__module__}.{type(reader).__name__}",
            "store_class": f"{type(store).__module__}.{type(store).__name__}",
            "schema_version": record_store.SCHEMA_VERSION,
            "status_outcome": reader.status()["outcome"],
        }) + "\n")
        return 0

    if opts.seed_from_golden_vectors:
        try:
            report = seed_from_golden_vectors(os.environ.get(SIDECAR_PATH_ENV), record_store,
                                              store, opts.seed_from_golden_vectors)
        except ServerRefused as exc:
            sys.stderr.write(f"{exc}\n")
            return 2
        except Exception as exc:                                   # noqa: BLE001
            sys.stderr.write(f"{type(exc).__name__}: {exc}\n")
            return 2
        # The seed is announced on STDERR, never on stdout: stdout is the protocol stream, and a
        # non-frame line there would desynchronise the client. The label travels with it.
        sys.stderr.write(f"SEEDED from V1-shaped golden vectors (NOT DEV data, NOT a producer): "
                         f"cards={report.cards} records={report.records} epoch={report.epoch} "
                         f"position={report.position}\n")
        sys.stderr.flush()

    serve(reader, i2_read, sys.stdin, sys.stdout)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
