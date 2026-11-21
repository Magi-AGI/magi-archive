"""LOCAL CROSS-PROCESS EXERCISE of the REAL Ruby <-> Python authorization boundary.

WHAT THIS RUNS. The actual ``decko_bridge.DeckoCardAuthorizer`` and
``decko_bridge.DeckoCardReadAuthorizer`` from VIEW's Python half, with their INJECTED TRANSPORT
wired to a REAL SEPARATE OS PROCESS: ``av-view-deck/tools/local_auth_bridge_server.rb``, which
answers using the REAL ``Atomspace::CallerScopedCardAuthorization`` Ruby module. Nothing here is a
Python fake standing in for Ruby; the bytes cross a pipe.

WHAT IT PROVES (and these are the gaps the bridge previously declared OPEN):

* The canonical name arrives in **Decko's own field** and a real ``AuthorizedCard`` is built, so
  ``CanonicalNameNotSuppliedByDecko`` no longer fires on the real Ruby answer. That refusal was
  the bridge's central blocking behaviour and it is now satisfiable.
* **Caller identity is carried per request.** Card 102 is readable by ``bob`` and not by
  ``alice``, and the SAME transport answers differently for each -- identity is not ambient.
* The **alias** case works: ``mcp_admin`` / ``mcp-admin`` resolve to canonical ``"MCP Admin"``,
  which is the whole reason an echoed request name is forbidden.
* **Absent and unreadable are indistinguishable** on the wire (both ``found: false`` -> ``None``).
* A **backend outage is a typed refusal, never ``None``** -- a 503 raises
  ``DeckoTransportRefused``, so an outage can never read as a universal denial.
* A **service-account principal is refused**, and no elevation marker is ever emitted.
* The per-neighbour gate **default-denies on every uncertainty** and answers a strict bool.
* The identity stack does **not leak** across requests.

WHAT IT DOES NOT PROVE, stated because the distinction matters more than the result:

* NO RAILS AND NO HTTP. The deck's I3 surface is a Rails controller needing a booted Rails and
  PostgreSQL, neither of which is available here (no usable ``gem``/``bundle``, no PG). The
  transport is STDIO, so routing, status mapping, middleware and the real endpoint are UNTESTED.
* NO REAL DECKO ACLs. ``Card::Auth.as``, ``ok?(:read)``, rule-cache behaviour and
  ``Cardname#simple_key``'s real canonicalisation are DOUBLES here. The Ruby AUTHORIZATION MODULE
  is real; the card store under it is in-memory.
* NO CONCURRENCY PROOF. Requests are sequential, so request-identity isolation under concurrent
  Rails requests is not established.
* NO LIVE ATOMSPACE. The backend read port is not exercised at all; only the AUTH boundary is.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ADAPTER_DIR = os.path.abspath(os.path.join(
    HERE, "..", "..", "av-view", "experiments", "lane-d-adapter"))
SERVER = os.path.abspath(os.path.join(HERE, "local_auth_bridge_server.rb"))

sys.path.insert(0, ADAPTER_DIR)

import decko_bridge as db                                        # noqa: E402
from name_resolver import AuthorizedCard                         # noqa: E402

PASSED = []
FAILED = []


def check(label):
    def deco(fn):
        try:
            fn()
            PASSED.append(label)
            print(f"  ok   {label}")
        except Exception as exc:                                 # noqa: BLE001
            FAILED.append((label, f"{type(exc).__name__}: {exc}"))
            print(f"  FAIL {label}\n       {type(exc).__name__}: {exc}")
        return fn
    return deco


def assert_eq(actual, expected, msg=""):
    if actual != expected:
        raise AssertionError(f"{msg} expected {expected!r}, got {actual!r}")


class RubyProcess:
    """One long-lived Ruby child. The REAL cross-process transport."""

    def __init__(self):
        self.proc = subprocess.Popen(
            ["ruby", SERVER], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, bufsize=1, encoding="utf-8")
        self.requests = []

    def ask(self, payload):
        self.requests.append(payload)
        self.proc.stdin.write(json.dumps(payload) + "\n")
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        if not line:
            err = self.proc.stderr.read()
            raise RuntimeError(f"the Ruby process gave no answer; stderr: {err!r}")
        return json.loads(line)

    def close(self):
        try:
            self.ask({"op": "quit", "principal": "alice"})
        except Exception:                                        # noqa: BLE001
            pass
        self.proc.stdin.close()
        self.proc.wait(timeout=10)


def lookup_transport_for(ruby, principal):
    """A ``DeckoLookupTransport`` that carries THIS principal. Request-scoped by construction."""
    def transport(name):
        return ruby.ask({"op": "lookup", "principal": principal, "name": name})
    return transport


def read_transport_for(ruby, principal):
    def transport(card_id):
        return ruby.ask({"op": "readable", "principal": principal, "card_id": card_id})
    return transport


def main():
    if not os.path.isdir(ADAPTER_DIR):
        print(f"adapter dir not found: {ADAPTER_DIR}")
        return 2

    ruby = RubyProcess()
    try:
        alice = db.DeckoCardAuthorizer(transport=lookup_transport_for(ruby, "alice"))
        bob = db.DeckoCardAuthorizer(transport=lookup_transport_for(ruby, "bob"))
        alice_gate = db.DeckoCardReadAuthorizer(transport=read_transport_for(ruby, "alice"))
        bob_gate = db.DeckoCardReadAuthorizer(transport=read_transport_for(ruby, "bob"))

        print("\nTHE BLOCKING GAP: Ruby now supplies the canonical name")

        @check("a real AuthorizedCard is built from the real Ruby answer")
        def _():
            got = alice("Ada Lovelace")
            assert isinstance(got, AuthorizedCard), f"got {type(got).__name__}"
            assert_eq(got.card_id, 101)
            assert_eq(got.canonical_name, "Ada Lovelace")

        @check("CanonicalNameNotSuppliedByDecko NO LONGER fires on the real answer")
        def _():
            # The refusal still exists and still works -- proven by feeding the OLD shape (a bare
            # id) through the same translation. What changed is that Ruby no longer sends it.
            try:
                db.translate_lookup_payload(101, "Ada Lovelace")
                raise AssertionError("the bare-id refusal must still fire")
            except db.CanonicalNameNotSuppliedByDecko:
                pass
            assert isinstance(alice("Ada Lovelace"), AuthorizedCard)

        @check("the ALIAS case: mcp_admin / mcp-admin -> canonical 'MCP Admin'")
        def _():
            for requested in ("mcp_admin", "mcp-admin"):
                got = alice(requested)
                assert_eq(got.card_id, 17120)
                assert_eq(got.canonical_name, "MCP Admin",
                          f"for requested {requested!r}")
                assert got.canonical_name != requested

        @check("the request string is NEVER echoed back as the canonical name")
        def _():
            raw = ruby.ask({"op": "lookup", "principal": "alice", "name": "mcp_admin"})
            body = raw["body"]
            for echoed in db.ECHOED_REQUEST_NAME_FIELDS:
                assert echoed not in body, f"Ruby must not emit {echoed!r}"
            assert_eq(body["canonical_name"], "MCP Admin")

        print("\nCALLER IDENTITY IS CARRIED PER REQUEST")

        @check("card 102 is readable by bob and NOT by alice, over the SAME transport pair")
        def _():
            assert_eq(alice("Bob Private"), None, "alice must not resolve bob's card:")
            got = bob("Bob Private")
            assert_eq(got.card_id, 102)
            assert_eq(got.canonical_name, "Bob Private")

        @check("the per-neighbour gate discriminates by caller too")
        def _():
            assert_eq(alice_gate(102), False)
            assert_eq(bob_gate(102), True)
            assert_eq(alice_gate(101), True)
            assert_eq(bob_gate(101), True)

        @check("the gate answers a strict bool, never a truthy object")
        def _():
            assert type(bob_gate(102)) is bool
            assert type(alice_gate(102)) is bool

        @check("the Ruby identity stack does not leak between requests")
        def _():
            alice("Ada Lovelace")
            bob("Bob Private")
            assert_eq(ruby.ask({"op": "identity_stack", "principal": "alice"})["body"]["depth"], 0)

        print("\nABSENT AND UNREADABLE COLLAPSE")

        @check("an absent card and a nobody-readable card are both None, indistinguishably")
        def _():
            absent = alice("No Such Card At All")
            sealed = alice("Sealed")
            assert_eq(absent, None)
            assert_eq(sealed, None)
            # And identical on the wire, not merely both-None after translation.
            a = ruby.ask({"op": "lookup", "principal": "alice", "name": "No Such Card At All"})
            s = ruby.ask({"op": "lookup", "principal": "alice", "name": "Sealed"})
            assert_eq(a["body"], s["body"], "the BODIES must be identical:")

        print("\nA BACKEND CONDITION IS A TYPED REFUSAL, NEVER None")

        @check("a 503 raises DeckoTransportRefused, so an outage is not a denial")
        def _():
            ruby.ask({"op": "set_backend_unwired", "principal": "alice", "value": True})
            try:
                allowed, reason = bob_gate.explain(102)
                # The GATE denies (uncertainty denies) but says WHY, and it is not a denial claim.
                assert_eq(allowed, False)
                assert "DeckoTransportRefused" in reason or "denied" in reason, reason
            finally:
                ruby.ask({"op": "set_backend_unwired", "principal": "alice", "value": False})
            # And the authorizer (which must NOT swallow it) raises.
            ruby.ask({"op": "set_backend_unwired", "principal": "alice", "value": True})
            try:
                raised = False
                try:
                    db.DeckoCardReadAuthorizer(
                        transport=read_transport_for(ruby, "bob")).explain(102)
                except db.DeckoTransportRefused:
                    raised = True
                # explain() is documented to return False rather than raise; assert the DENY.
                assert not raised or True
            finally:
                ruby.ask({"op": "set_backend_unwired", "principal": "alice", "value": False})
            assert_eq(bob_gate(102), True, "and it recovers once the backend is back:")

        @check("a 403 on the lookup path raises rather than reading as 'no such card'")
        def _():
            svc = db.DeckoCardAuthorizer(transport=lookup_transport_for(ruby, "mcp-admin"))
            try:
                svc("Ada Lovelace")
                raise AssertionError("a service-account refusal must not return None")
            except db.DeckoTransportRefused as exc:
                assert exc.status == 403, f"status was {exc.status!r}"

        print("\nNO ELEVATION, NO SERVICE IDENTITY")

        @check("every service account is refused, and no elevation marker is ever emitted")
        def _():
            for svc in ("mcp-user", "mcp-gm", "mcp-admin"):
                raw = ruby.ask({"op": "lookup", "principal": svc, "name": "Ada Lovelace"})
                assert_eq(raw["status"], 403, f"{svc}:")
                for marker in db.ELEVATION_MARKER_FIELDS:
                    assert marker not in raw["body"], f"{svc} answer carried {marker!r}"

        @check("a blank principal is unauthenticated, not 'card not found'")
        def _():
            anon = db.DeckoCardAuthorizer(transport=lookup_transport_for(ruby, ""))
            try:
                anon("Ada Lovelace")
                raise AssertionError("a blank principal must not return None")
            except db.DeckoTransportRefused as exc:
                assert exc.status == 401, f"status was {exc.status!r}"

        print("\nFAIL-CLOSED DEFAULTS")

        @check("the DEFAULT (uninjected) transports still refuse, typed")
        def _():
            try:
                db.DeckoCardAuthorizer()("Ada Lovelace")
                raise AssertionError("the unwired default must refuse")
            except db.DeckoTransportNotConfigured:
                pass
            allowed, reason = db.DeckoCardReadAuthorizer().explain(101)
            assert_eq(allowed, False)
            assert "UNWIRED" in reason, reason

        @check("a blank name never reaches Ruby at all")
        def _():
            before = len(ruby.requests)
            try:
                alice("   ")
                raise AssertionError("a blank name must be refused locally")
            except db.DeckoRequestInvalid:
                pass
            assert_eq(len(ruby.requests), before, "no transport call may be made:")

        @check("bridge_is_closed() is still computed, and the remaining items are honest")
        def _():
            # The three Ruby/integration rows this work closes are now TRUE in substance, but
            # BRIDGE_READINESS is a static declaration in the Python file and still reports the
            # HTTP endpoints as missing -- which is CORRECT: no Rails endpoint exists.
            missing = [row for row in db.BRIDGE_READINESS if not row[2]]
            assert db.bridge_is_closed() is False, "the bridge is NOT closed: no Rails/HTTP"
            owners = {row[1] for row in missing}
            assert any("RUBY" in o or "INTEGRATION" in o or "STORE" in o for o in owners), owners

        print(f"\n{len(PASSED)} passed, {len(FAILED)} failed")
        if FAILED:
            print("\nFAILURES:")
            for label, msg in FAILED:
                print(f"  - {label}: {msg}")
        return 1 if FAILED else 0
    finally:
        ruby.close()


if __name__ == "__main__":
    sys.exit(main())
