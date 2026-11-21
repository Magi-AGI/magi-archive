# frozen_string_literal: true

require_relative "errors"
require_relative "i2_envelope"
require_relative "i3_read_result"

module Atomspace
  # THE ONE SHARED, CONTRACT-CORRECT I3 RESPONSE RENDERER.
  #
  # Every I3 read response -- lookup, open, neighbours, and every non-refusal failure -- is composed
  # HERE and nowhere else. One implementation, so the envelope cannot drift between three handlers.
  #
  # ==== THE AUTHORITATIVE CONSUMER CONTRACT (this is what the shape is FOR)
  #
  # `av-client/src/demo/live-bridge.mjs` is the real parser and it is NOT modified to accommodate
  # this deck. Its three checks, at `:762-795` `checkI3Body`, are:
  #
  #   1. TOP-LEVEL `outcome` must be one of the nine (`:122-124` NINE_OUTCOMES).
  #   2. All six of `outcome, epoch, position, read-at, schema-version, limits` must be PRESENT --
  #      `hasOwnProperty`, so JSON `null` is a legal VALUE but an absent KEY is a violation
  #      (`:132-137` ENVELOPE_FIELDS, `:777-783`).
  #   3. An all-null `(epoch, position, read-at)` triple may appear ONLY on `not ready` /
  #      `unavailable` (`:143` NO_STATE_OUTCOMES, `:784-792`).
  #
  # K8 §5.2 (`av-contract/contracts/k8-draft-2.md:300-310`) is the governing source: "Every
  # response, including every failure that is not a refusal, begins with" the envelope, whose rows
  # are in exactly the order this module emits. §5.2 `:386-406` is the no-state rule: the three are
  # "all three PRESENT ... Each of the three carries exactly the JSON value `null` ... Omitting any
  # of the three is non-conforming, and so is a mix".
  #
  # The previous Rails-shaped `{results:, _meta:}` body failed check 1 on the first assertion: it
  # has no top-level `outcome` at all. That is the defect this module repairs.
  #
  # ==== WHAT IS FORWARDED VERBATIM AND WHAT IS REFUSED
  #
  #   * `outcome` / `epoch` / `position` / `read-at` come from the VALIDATED STORE envelope carried
  #     on I3ReadResult. They are STORE's own sampled values. NOTHING here mints, defaults, coerces
  #     or re-stamps one: there is no `||`, no `.to_i`, no `.to_s`, and NO CLOCK CALL anywhere in
  #     this file. A missing or malformed metadatum is a REFUSAL, never a default.
  #   * `schema-version` is STORE's `payload["versions"]["schema"]` from I2-01, forwarded verbatim.
  #     It is deliberately NOT read from `I2Envelope::SCHEMA_VERSION`: that constant is VIEW's
  #     expectation, and emitting it would be VIEW asserting a schema the store never reported.
  #   * `limits` is composed from I2-01's own `page-max` / `fanout-limit` / `state-retain` /
  #     `label-bearing-properties` (`i2_read.py:710-728`), flattened to K8 §5.2's ten names.
  #     Flattening is a presentation of STORE's values, not a derivation of new ones.
  #   * `poll-interval-ms` HAS NO STORE SOURCE and is emitted as JSON `null`. The key is PRESENT
  #     because absence is itself a reportable violation for the client; the VALUE is null because
  #     inventing an interval would be fabricating a server ceiling.
  #   * `health` is OMITTED ENTIRELY, never `health: null`. STORE's health slice is O23-gated and
  #     deliberately absent upstream ("Absent, not fabricated: health (O23 gated)" --
  #     `i2_read.py:60`), so there is no health data and none is invented. This is a DECLARED GAP
  #     against K8 §5.3's `not ready` / `unavailable` / `degraded` payload column, not a silent one.
  #   * STORE's real `omitted` / `cursor-stale` / `counts` metadata is forwarded when STORE sent it.
  #     Dropping it would be replacing real metadata with a success default.
  module I3Envelope
    # Raised when a reading cannot be rendered conformantly. The controller maps it to the EXISTING
    # 503 backend path -- it never degrades into a success body.
    class Unrenderable < Atomspace::Error; end

    # The six unconditional envelope fields, in K8 §5.2 row order (`k8-draft-2.md:304-309`).
    # Key order is load-bearing for the recorded-corpus comparison (`LIVE-TRANSPORT.md:163-165`
    # compares `list(d.keys())` recursively), so the renderer emits them by explicit insertion.
    FIELDS = %w[outcome epoch position read-at schema-version limits].freeze

    # The three state metadata, i.e. FIELDS minus outcome/schema-version/limits.
    STATE_KEYS = %w[epoch position read-at].freeze

    # The nine outcomes, closed set (`k8-draft-2.md:478-488`, closure asserted `:1873-1874`).
    # Kept here as the RENDER-SIDE gate: STORE emits only five of the nine, and a value outside the
    # nine must never reach the wire even if some future reader answers one.
    NINE_OUTCOMES = [
      "ok", "ok, partial", "empty", "unknown", "excluded",
      "not ready", "degraded", "unavailable", "reload"
    ].freeze

    # The only two outcomes that may carry an all-null state triple (`k8-draft-2.md:495-498`;
    # client `live-bridge.mjs:143`).
    NO_STATE_OUTCOMES = ["not ready", "unavailable"].freeze

    # K8 §5.2's ten `limits` names, in the order the row lists them (`k8-draft-2.md:309`).
    LIMITS_KEYS = %w[
      page-max-entries page-max-connections page-max-bytes per-neighbour-link-max
      refresh-max-participants poll-interval-ms fanout-limit
      state-retain-ms state-retain-positions label-bearing-properties
    ].freeze

    # STORE payload keys this deck forwards onto the I3 body when STORE actually sent them. Each is
    # K8's OWN normative key, so forwarding adds no wire vocabulary: `omitted` is §5.8's
    # three-member omission report (`:777-794`), `cursor-stale` is §5.9's (`:744`), `counts` is
    # §5.6's four-member block (`:610-615`).
    FORWARDED_PAYLOAD_KEYS = %w[omitted cursor-stale counts].freeze

    # §5.8's `omitted` members that carry NO PARTICIPANT IDENTITY and may therefore be forwarded
    # exactly as STORE sent them (see .authorize_omission for the full argument):
    #   * `bound` is a member of a CLOSED seven-value enumeration (`k8-draft-2.md:782-789`) --
    #     a category name, naming no card;
    #   * `count` is an integer cardinality -- "how many were left out, exact" (`:791`). A count
    #     is not an identity: it says how many rows the STORE truncated, never which;
    #   * `reason` on the §5.4 ambiguous-digest path is a fixed diagnostic string (O31).
    # Anything OUTSIDE this set plus `continue` is a member this deck cannot audit, and an
    # unauditable member is dropped rather than forwarded blind.
    IDENTITY_FREE_OMISSION_KEYS = %w[bound count reason].freeze

    # The `continue` item keys that name a PARTICIPANT by its STORE key text. Each must be
    # authorized against the caller's read authority before it may leave this process.
    #   * `key`         -- §5.8's `{key, digest}` candidate form (`i2_read.py:705-706`);
    #   * `after`       -- the cursor's last-entry ORDER TUPLE (`i2_read.py:697-699`);
    #   * `participant` -- the cursor's subject key (same);
    #   * `neighbour`   -- the link-level cursor's neighbour order tuple (`i2_read.py:615-618`).
    #
    # THESE ARE AUTHORIZED AT EVERY NESTING DEPTH, not just on an item's own top level (see
    # .continue_node_authorized? for the defect that required this).
    #
    # ==== `after` AND `neighbour` ARE ORDER TUPLES, NOT BARE KEY TEXTS (the dead-end this repairs)
    #
    # THE DEFECT. `continue_identity_authorized?` required a String and failed closed on anything
    # else, and STORE's REAL `after` is NOT a String -- it is `_order(...)`, a THREE-ELEMENT ARRAY:
    #     "after": ["(Card 19360)", "", -1]                    (measured, STORE 042 seq 17-20)
    # So EVERY real page-out continuation hit the non-String branch, was declared unauthorized, and
    # the WHOLE continuation was dropped -- on pages whose identities the caller could read
    # perfectly well. The client then saw `ok, partial` with `bound` and `count` but NO cursor: a
    # truncated page it had no way to resume, and no statement that it could not. That is a SILENT
    # PAGING DEAD END, and §5.8 requires a truncated page to carry "the exact total and a
    # continuation cursor" (`k8-draft-2.md:773`), so the drop was not merely unhelpful -- it broke
    # the contract while LOOKING like a conservative ACL decision.
    #
    # THE FIX. An identity value may also be an ARRAY, and it is authorized ELEMENT-WISE by the
    # same rules, with the same fail-closed direction (see .continue_identity_authorized?):
    #   * a non-empty String element -> an identity, authorized by the caller's predicate;
    #   * `nil` or the EMPTY String -> names nobody (STORE's second tuple slot is `""` on a
    #     participant-ordered page), so it is admissible without an ACL question;
    #   * a Numeric / boolean element -> an ORDER COORDINATE (STORE's third slot is `-1`), not an
    #     identity, so likewise;
    #   * a Hash or a nested Array INSIDE an identity tuple -> UNAUTHORIZED. A shape this deck
    #     cannot read as an identity is one it must not forward, exactly as before.
    # Nothing is parsed FOR MEANING and nothing is derived from the tuple: its elements are only
    # handed to the existing ACL. The cursor stays opaque in the §5.8:734 sense -- this deck reads
    # it solely to authorize it, never to interpret or reconstruct it.
    CONTINUE_IDENTITY_KEYS = %w[key after participant neighbour].freeze

    # `continue` keys whose value is a LINK KEY TEXT, audited by the link-key participant audit
    # rather than as a flat identity.
    #
    # `after-link` is the link-level continuation key (`i2_read.py:615-618`). A LINK key text
    # EMBEDS THE CARD ADDRESS OF EVERY PARTICIPANT of that link, so it cannot be handed to the
    # flat `(Card <digits>)` ACL as one identity -- that was the stated reason it used to be
    # excluded from the allowlist entirely, which made every link-level cursor unrecognised and
    # therefore dropped. The audit it actually needs ALREADY EXISTS and is the same one every
    # emitted link goes through (.link_key_participants): quoted data is stripped, top-level
    # positions are enumerated, and EVERY position must be authorized. So `after-link` is admitted
    # as a KNOWN key and authorized by that audit -- not waved through as "structural", and not
    # given a new ACL.
    CONTINUE_LINK_KEY_KEYS = %w[after-link].freeze

    # `continue` item keys that are structural, not identities: the §5.8 `no-such-bucket` form
    # `{bucket, cursor, reason}` (`k8-draft-2.md:793-799`) names a REQUESTED bucket (a link-type
    # head the CALLER supplied) with a `cursor` that is present and exactly null, plus the cursor
    # form's own non-identity fields. None of these names a card.
    #
    # `cursor` STAYS ACCEPTED as a key and is NOT rejected: on the §5.8 `no-such-bucket` path it is
    # legitimately present and exactly null (`k8-draft-2.md:793-799`). What changed is that when it
    # holds a HASH its CONTENTS are now inspected, because STORE's real `_cursor`
    # (`i2_read.py:695-700`) puts `participant` and `after` INSIDE it.
    CONTINUE_STRUCTURAL_KEYS = %w[bucket cursor reason kind narrowing epoch position digest].freeze

    # `digest` IS AN IDENTITY-BEARING ADDRESS, and it is handled by a PAIRING RULE rather than by
    # the plain identity path. The deliberate decision, and why:
    #
    #   * IT REALLY IS AN ADDRESS. STORE accepts `{"digest": <hex>}` as a participant address
    #     (`i2_read.py:474-482`), confirmed by a real probe. So a digest that reaches a caller who
    #     may not read the card it addresses is the SAME read-permission oracle a leaked `key` is:
    #     the caller can turn around and address the card with it. Leaving it purely "structural"
    #     would be wrong.
    #
    #   * BUT IT CANNOT BE AUTHORIZED ON ITS OWN. The digest is the STORE's, computed over the
    #     store's complete key index (`i3_read_port.rb:21-25`), and this deck is FORBIDDEN to
    #     compute one. There is no digest -> card-id resolver anywhere -- the port header records
    #     that the whole name/digest -> key mapping DOES NOT EXIST UPSTREAM YET -- so handing a
    #     digest to the `authorize` predicate can only ever return false, which would drop EVERY
    #     continuation including a fully readable one. That is not authorization, it is a blanket
    #     drop dressed up as one.
    #
    #   * SO: A DIGEST TRAVELS ONLY WHEN IT IS PAIRED WITH AN AUTHORIZED `key` IN THE SAME NODE.
    #     That is exactly the one form STORE emits it in (`{"key": k, "digest": digest_fn(k)}`,
    #     `i2_read.py:705-706`), and in that form the `key` beside it IS authorizable and IS
    #     authorized. A digest with no sibling `key` text is an address this deck cannot check, so
    #     it FAILS CLOSED -- the node is unauthorized and the whole continuation is dropped. The
    #     digest therefore never outlives the authorization of the card it addresses.
    CONTINUE_PAIRED_ADDRESS_KEYS = %w[digest].freeze

    # Every key admissible anywhere inside a `continue` item, at any depth. An unrecognised key
    # could be a FUTURE IDENTITY FORM, so encountering one FAILS CLOSED rather than being assumed
    # harmless -- the same rule that already governed the top level, now applied all the way down.
    CONTINUE_KNOWN_KEYS =
      (CONTINUE_IDENTITY_KEYS + CONTINUE_LINK_KEY_KEYS + CONTINUE_STRUCTURAL_KEYS).freeze

    # THE UNRESOLVED-TARGET PARTICIPANT, AND WHY IT IS NOT A CARD AND NOT AN INDEPENDENT IDENTITY.
    #
    # K8 §5.6 N04 is explicit, and it decides this case rather than this deck deciding it:
    #     "An unresolved target `(Wanted \"k\")` belongs to its one link, has no neighbourhood, and
    #      is never shared between links; two links wanting the same missing key are not
    #      connected."                                             (`k8-draft-2.md:630-631`)
    #
    # Three consequences follow directly from that sentence, and all three are load-bearing here:
    #
    #   1. IT HAS NO IDENTITY OF ITS OWN TO AUTHORIZE. It is not addressable as a subject -- "has
    #      no neighbourhood" means there is no I3-02/I3-03 answer about it -- so there is no card
    #      whose readability could be asked about. Handing `(Wanted "markdown+description")` to a
    #      `(Card <digits>)` ACL can only ever return false, which is why the previous code dropped
    #      it: not a permission decision, a type mismatch dressed as one.
    #   2. IT RIDES ITS OWNING LINK. "Belongs to its one link" and "is never shared between links"
    #      mean the link IS its scope. So the authorization question that CAN be asked, and the one
    #      this deck asks, is whether the caller may read the link that owns it -- i.e. every
    #      `(Card <digits>)` participant of that link, which is exactly the existing per-link
    #      audit. If the owning link is readable, the unresolved target discloses nothing the
    #      caller was not already entitled to see; if it is not, the link is dropped and the target
    #      goes with it.
    #   3. IT IS NOT A GLOBAL ALLOW. Only heads STORE ITSELF DECLARED as unresolved-target
    #      constructors qualify, and the declaration is read off STORE's own I2-07 answer (see
    #      .unresolved_heads_from_declarations). `Wanted` is NOT hardcoded: K8 lists it as one
    #      constructor (`:88`, `:99-101`) and STORE's heads are runtime-declared, so a hardcoded
    #      name would be this deck inventing store vocabulary. With NO declarations supplied the
    #      set is EMPTY and every non-Card position fails closed exactly as before -- the
    #      permissive direction is unreachable without STORE's own declaration.
    #
    # The signature STORE publishes for such a head has result type `Unresolved` (measured on the
    # real reader child, STORE 042 seq 3: `{"head": "Wanted", "signature": {"arguments":
    # ["String"], "result": "Unresolved"}}`), which is the one fact used to recognise it.
    UNRESOLVED_SIGNATURE_RESULT = "Unresolved"

    # Depth ceiling for the recursive authorization walk. STORE's deepest real continuation shape is
    # ONE level of nesting (`{bucket, cursor:{...}}`), so this is generous; it exists so a
    # pathologically deep or self-referential structure cannot exhaust the stack. Exceeding it is
    # treated as UNAUTHORIZED, not as acceptable -- a structure this deck cannot finish auditing is
    # one it must not forward.
    CONTINUE_MAX_DEPTH = 8

    # THE LINK-KEY PARTICIPANT AUDIT -- STRUCTURAL, AND EXACTLY AS NARROW AS THIS DECK'S ACL.
    #
    # A STORE link key is an EXPRESSION whose members INCLUDE THE PARTICIPANTS' CARD ADDRESSES.
    # Measured against the real reader child (`store-raw-probe.json`):
    #     "(created-by (Card 2) (Card 1))"
    #     "(includes (Card 2) (Card 34) \"rich_text+description\")"
    #     "(updated-by (Card 1) (Card 201))"
    # and `k8-draft-2.md:624-628` documents links with THREE OR MORE participants. So one link key
    # text discloses the identity of EVERY participant of that link -- not only the entry whose
    # `links[]` it sits in.
    #
    # ==== WHAT IS ACTUALLY ENFORCED (and what the previous comment here OVERCLAIMED)
    #
    # This deck can authorize EXACTLY ONE participant form: `(Card <digits>)`. That is the only
    # form the single ACL maps (`i3_read_controller.rb:1040-1048` /
    # #card_id_from_store_key_text), so it is the only identity whose readability this module can
    # ask about. `Card` IS NOT A STORE CONSTANT: STORE's participant heads are RUNTIME-DECLARED
    # and fitted over `_PARTICIPANT_TYPES = ("Entity", "Link", "%Undefined%")`
    # (`i2_read.py:93`, `_signature`, `_Fitter#link_members`); `grep -c Card i2_read.py` is ZERO.
    # K8 itself documents a NON-Card participant form -- the unresolved target `(Wanted "k")`,
    # which "belongs to its one link" (`k8-draft-2.md:630`) -- and av-fixtures declares
    # `(: Wanted ...)` beside `(: Card ...)`.
    #
    # So the enforced rule is NOT "every identity is authorized universally". It is:
    #   * EVERY participant position of the link key must be EXACTLY `(Card <digits>)`, AND every
    #     one of those must be authorized by the injected `authorize` predicate -> the link is
    #     emitted, STORE's own object, byte-identical.
    #   * ANY participant position in ANY OTHER FORM -- `(Wanted ...)`, `(Unresolved ...)`, a
    #     nested link, a future declared head, a bare token, anything unrecognised -- is an
    #     identity THIS DECK CANNOT AUTHORIZE, so the LINK IS DROPPED. Unauthorizable is treated
    #     as unauthorized. That is the whole correction: the previous rule scanned for
    #     `(Card \d+)` GLOBALLY and rejected only the zero-match case, so a key MIXING an
    #     authorized `(Card N)` with a non-Card participant satisfied `all?` and rode out WHOLE,
    #     disclosing that other participant.
    #   * ZERO authorizable participants, a non-String key, a non-Hash link, a key that is not a
    #     well-formed expression -> DROPPED, same direction.
    #
    # ==== QUOTED DATA IS DATA, NEVER A PARTICIPANT POSITION
    #
    # A link key embeds its DATA members as `json.dumps` string literals (`i2_read.py:183`) --
    # measured: `(includes (Card 2) (Card 34) "rich_text+description")`. Those literals are
    # STRIPPED BEFORE the structure is read, so their contents can never be mistaken for a
    # participant. A link whose data merely CONTAINS the text `(Card 99)` -- e.g.
    # `(links-to (Card 7) "see (Card 99) for detail")` -- is therefore NOT over-redacted: its real
    # participants are what is audited. The previous global scan treated that `99` as a
    # participant and silently dropped a genuinely readable link.
    #
    # ==== AUTHORIZATION-ONLY, AND ONE ACL
    #
    # The `(Card <id>)` texts this audit derives exist solely to be handed to the CALLER's
    # existing `authorize` predicate. NOTHING derived here is ever emitted: the only thing that
    # reaches the wire is STORE's own link object, unchanged, and only when every participant
    # position was both recognisable AND authorized. There is still exactly ONE ACL and this
    # module implements none of it.
    #
    # ==== AND THE DROP IS WHOLE-LINK
    #
    # A link's `digest` is an address STORE ACCEPTS (`i2_read.py:474-482`), so it may never
    # outlive the authorization of the key it belongs to -- the same pairing rule as
    # CONTINUE_PAIRED_ADDRESS_KEYS. Its remaining members (`link-type`, `subject-positions`,
    # `neighbour-positions`, `copy-count`, `is-participant`) carry no identity but are dropped
    # WITH it anyway: a positions-and-counts object with its key and digest stripped would be a
    # NEW wire shape this lane would be coining, and the whole-object drop is the existing
    # safe-direction precedent (`atom_from_entry!` / `filter_by_read_auth` drop an unattributable
    # atom whole rather than emitting a redacted one).

    # The ONE participant form this deck's ACL can map, anchored so it matches a WHOLE position
    # rather than a substring of one. Authorization-only; never emitted.
    LINK_KEY_CARD_POSITION_PATTERN = /\A\(Card (\d+)\)\z/

    # A `json.dumps` string literal (`i2_read.py:183`), including backslash escapes. Stripped
    # before the structure is read, so quoted DATA is never read as a participant position.
    LINK_KEY_QUOTED_DATA_PATTERN = /"(?:\\.|[^"\\])*"/

    # What a stripped quoted literal is replaced by while the structure is parsed. It occupies the
    # position as a DATA position and is never authorized and never emitted. NUL cannot occur in
    # STORE's key text for a string member (`json.dumps` escapes control characters as `\u0000`
    # six-character sequences, never raw), so this marker cannot be forged from STORE output; a
    # key containing a raw NUL at all is rejected outright rather than parsed.
    LINK_KEY_DATA_POSITION = "\u0000data\u0000"

    class << self
      # Compose one I3 response body.
      #
      # @param result [Atomspace::I3ReadResult] the carrier holding STORE's VALIDATED envelope.
      # @param profile [Hash, nil] the store profile from .profile_from_status_payload, supplying
      #   `schema-version` and `limits`. nil when I2-01 was never reached -- both are then rendered
      #   as JSON `null` rather than guessed.
      # @param payload [Hash] the ORDERED endpoint payload keys to append after the envelope.
      # @param outcome [String, nil] overrides the carried outcome. Permitted ONLY when the carrier
      #   holds no STORE envelope (a no-state reading) or for the lookup-miss `unknown` rule, both
      #   of which are cases where STORE answered about something other than this request.
      # @param state [Hash, nil] the state triple source when the carrier has no envelope.
      # @return [Hash] insertion-ordered: the six envelope fields, then the payload keys.
      def compose(result:, profile: nil, payload: {}, outcome: nil, state: nil)
        raise Unrenderable, "result must be an I3ReadResult" unless result.is_a?(Atomspace::I3ReadResult)
        raise Unrenderable, "payload must be a Hash" unless payload.is_a?(Hash)

        envelope = result.envelope
        effective_outcome = outcome || (envelope && envelope["outcome"])
        raise Unrenderable, "no outcome: neither STORE nor the caller supplied one" if effective_outcome.nil?
        unless NINE_OUTCOMES.include?(effective_outcome)
          raise Unrenderable, "outcome #{effective_outcome.inspect} is outside the nine"
        end

        triple = state_triple(envelope: envelope, state: state, outcome: effective_outcome)

        body = {}
        body["outcome"] = effective_outcome
        STATE_KEYS.each { |k| body[k] = triple[k] }
        body["schema-version"] = profile && profile["schema-version"]
        body["limits"] = profile && profile["limits"]
        payload.each { |k, v| body[k.to_s] = v }
        body
      end

      # Append STORE's real omission/staleness/count metadata to an endpoint payload.
      #
      # Called with STORE's payload; copies ONLY the keys STORE actually sent. An absent key stays
      # absent -- no `omitted: null`, which would assert "nothing was omitted" without evidence.
      #
      # ==== `omitted` IS AUTHORIZED, NOT COPIED (the continuation-identity leak this repairs)
      #
      # THE DEFECT. This method used to copy `omitted` through UNCHANGED, AFTER the caller had
      # already ACL-filtered the atom list. STORE's `omitted.continue` carries THE IDENTITY OF
      # ENTRIES -- `{key, digest}` candidate items on the ambiguous-digest path
      # (`i2_read.py:705-706`) and the cursor's `after` / `participant` keys
      # (`i2_read.py:697-699`). So an atom that `filter_by_read_auth` REMOVED from `results`
      # because the caller may not read its card remained IDENTIFIABLE in `omitted.continue[].key`
      # / `.after`. That is a read-permission oracle through the back door: the caller learns the
      # key text -- and therefore the existence -- of a card the ACL just denied them. It defeats
      # the same non-oracle requirement the whole surface is built around, and an ACL filter that
      # can be read around is not a filter.
      #
      # THE FIX, AND ITS FAIL-CLOSED DIRECTION. Every identity inside `continue` is checked against
      # THE SAME allow-set the atom list was filtered with. The caller passes an `authorize` lambda
      # (store key text -> Boolean) built from the caller's own read authority; there is no second
      # ACL implementation here and no identity is authorized by this module itself.
      #   * an item whose every identity is authorized -> KEPT, verbatim;
      #   * an item carrying ANY unauthorized identity -> the WHOLE `continue` list is DROPPED;
      #   * an item carrying an identity this deck CANNOT MAP to a card id to check -> likewise
      #     DROPPED;
      #   * no `authorize` supplied at all -> DROPPED.
      # Dropping the WHOLE list rather than the offending items is deliberate: §5.8's `continue` is
      # a CONTINUATION, and a partially-pruned cursor would silently skip readable entries, making
      # the client's next page wrong instead of merely shorter. Absence is honest -- the client sees
      # no continuation and re-reads -- whereas a leaked identity cannot be taken back and a
      # mis-seeded cursor corrupts the read. `bound` and `count` SURVIVE the drop (see
      # IDENTITY_FREE_OMISSION_KEYS): they carry no identity, so forwarding them still reports
      # truthfully THAT and HOW MANY rows STORE omitted, without saying WHICH.
      #
      # NO NEW VOCABULARY IS COINED. Nothing is added to `omitted`: no eighth `bound` member (the
      # enumeration is CLOSED at seven, `k8-draft-2.md:782-789`), no new top-level key, no marker
      # saying the continuation was withheld. The members emitted are a SUBSET of the ones STORE
      # sent, which is why this is a filter and not an amendment.
      #
      # @param authorize [#call, nil] store-key-text -> Boolean, under the CALLER's identity.
      def forward_store_metadata(into, store_payload, authorize: nil)
        return into unless store_payload.is_a?(Hash)

        FORWARDED_PAYLOAD_KEYS.each do |key|
          next unless store_payload.key?(key)

          into[key] = if key == "omitted"
                        authorize_omission(store_payload[key], authorize)
                      else
                        store_payload[key]
                      end
        end
        into
      end

      # Authorize one §5.8 `omitted` report. See .forward_store_metadata for the argument.
      #
      # @return [Object] the report with an authorized `continue`, or with `continue` absent, or
      #   the value unchanged when it is not a mapping this deck can audit.
      def authorize_omission(omitted, authorize)
        # A LIST form (one report per missing bucket) is audited element-wise by the same rule.
        return omitted.map { |o| authorize_omission(o, authorize) } if omitted.is_a?(Array)
        # Not a mapping -> there is no `continue` to audit and no identity to leak.
        return omitted unless omitted.is_a?(Hash)

        kept = {}
        omitted.each do |k, v|
          next if k == "continue"

          # IDENTITY-FREE members pass through verbatim; an UNRECOGNISED member is dropped,
          # because this deck cannot prove it carries no identity and must not guess that it does.
          kept[k] = v if IDENTITY_FREE_OMISSION_KEYS.include?(k)
        end

        if omitted.key?("continue")
          authorized = authorized_continue(omitted["continue"], authorize)
          # nil means "not safely returnable" -> the key is ABSENT, not null: `continue: null` would
          # assert "there is nothing to continue from", which is a different and false claim.
          kept["continue"] = authorized unless authorized.nil?
        end

        kept
      end

      # THE STRUCTURED STORE-GRAPH PROJECTION -- ACL-applied, vocabulary-free, absence-preserving.
      #
      # ==== THE DEFECT THIS REPAIRS (the graph could not be ingested at all)
      #
      # The controller's card-scoped renderer built its whole payload as
      #     payload = { "results" => filtered.map(&:to_h) }
      # which REDUCES STORE's structured answer to a FLAT Array<Atom>. STORE's real I2-09 `open`
      # payload is `{"participant": {...}, "buckets": [...]}` and its real I2-03 `neighbours`
      # payload is `{"entries": [...]}`, so the participant's own address, its label, its
      # properties, every bucket's link-type and counts, and every entry's class/links were all
      # flattened away or dropped.
      #
      # And `results` IS NOT READ BY ANY CONSUMER. `av-client/src/drawn-graph.mjs` ingests the
      # drawn graph from `response.participant`, `response.buckets[]`, `response.entries[]`,
      # `response.bucket`, `response.counts` and `response['self-links']` -- it never looks at
      # `results`. So the structured graph had no path to the client. The loss was ENTIRELY in this
      # projection: `I3ReadResult#payload` already carries STORE's whole payload, unflattened.
      #
      # ==== WHAT THIS EMITS, AND THE FOUR RULES IT OBEYS
      #
      #   1. ONLY WHAT STORE SENT. Every key is copied from `store_payload` and only when STORE
      #      actually sent it. An absent STORE key stays ABSENT -- never `null`, never `[]`. A
      #      `buckets: []` would assert "this participant has no buckets" on an answer that said
      #      nothing about buckets, and that is a fabrication however small.
      #   2. NO NEW WIRE VOCABULARY. The only names emitted are K8's own -- `participant`,
      #      `buckets`, `entries`, `bucket`, `counts`, `self-links` -- and INSIDE them only the
      #      exact sub-keys STORE sent. Nothing is coined: no eighth `omitted.bound` member, no
      #      acl-filtered count, no marker saying an entry was dropped. A caller cannot tell an
      #      ACL-dropped entry from one STORE never sent, which is the non-oracle property.
      #   3. KEYS AND DIGESTS TRAVEL UNCHANGED. No key or digest is constructed, mangled, re-cased,
      #      normalised or recomputed anywhere here (VIEW is forbidden to compute a digest --
      #      `i3_read_port.rb:20-25`). Value types are preserved exactly: `participant.trash` is
      #      STORE's real boolean `false` while the `trash` PROPERTY atom's value is the STRING
      #      "False", and NEITHER is normalised into the other.
      #   4. AUTHORIZATION IS APPLIED BEFORE EMISSION, RECURSIVELY, AND FAILS CLOSED.
      #
      # ==== THE AUTHORIZATION RULE, in full
      #
      # `authorize` is a callable: STORE key text -> Boolean. It is the CALLER's own existing
      # default-deny check (the controller passes the SAME `store_identity_readable?` it already
      # uses for continuation identities), so there is exactly ONE ACL in the system and this
      # module implements none of it. This function is PURE over hashes: it does not touch Rails,
      # Card, or any ACL implementation.
      #
      #   * THE PARTICIPANT'S OWN `key` is authorized first. If it is denied -- or cannot be mapped
      #     and therefore cannot be checked -- NO participant is emitted, and because the whole
      #     structured graph hangs off the participant, NO structured graph is emitted at all. The
      #     caller gets the same shape as a store that sent nothing structured.
      #   * EVERY ENTRY's `key` is authorized, both in `buckets[].entries[]` and in the top-level
      #     `entries[]`. A denied entry -- or one whose key this deck cannot map to a card id --
      #     is DROPPED ENTIRELY: its digest, label, trash, counts and links go with it. Its links
      #     are not reattached anywhere; a dropped entry's links are dropped with it.
      #   * EVERY LINK OF A KEPT ENTRY IS AUTHORIZED SEPARATELY, AGAINST EVERY PARTICIPANT POSITION
      #     ITS KEY NAMES. This is the NESTED JOINING-LINK rule and it is NOT implied by the entry
      #     check. A STORE link key text EMBEDS THE IDENTITY OF EVERY PARTICIPANT of that link --
      #     measured: `"(created-by (Card 2) (Card 1))"`,
      #     `"(includes (Card 2) (Card 34) \"rich_text+description\")"` -- and K8 documents links
      #     with three or more participants (`k8-draft-2.md:624-628`). Authorizing only the ENTRY
      #     therefore left a readable entry able to DISCLOSE A DENIED THIRD PARTICIPANT's address,
      #     since the link rode out verbatim with its key and its digest. The key is now AUDITED
      #     STRUCTURALLY: its quoted DATA literals are stripped first (`i2_read.py:183`), its
      #     top-level positions are enumerated, and the link is emitted ONLY when EVERY position is
      #     exactly `(Card <digits>)` -- the one form this deck's single ACL can map -- and every
      #     one of those is authorized by that SAME `authorize` predicate. A position in ANY OTHER
      #     FORM (`(Wanted "k")`, `k8-draft-2.md:630`; `(Unresolved ...)`; a nested link; any
      #     future declared head) is an identity this deck CANNOT authorize, so the link is
      #     DROPPED. A key naming NO authorizable participant, or one that is not a well-formed
      #     expression, is DROPPED too -- an identity form this deck cannot enumerate is one it
      #     cannot audit. QUOTED DATA IS DATA: a link whose string member merely CONTAINS the text
      #     `(Card 99)` is NOT over-redacted, because that text never occupies a position.
      #   * A DROPPED LINK IS DROPPED WHOLE and the ENTRY SURVIVES. That is the existing
      #     safe-direction precedent (`atom_from_entry!` / `filter_by_read_auth` drop an
      #     unattributable atom rather than failing the whole read), and it keeps a readable
      #     entry readable. If EVERY link of an entry is dropped the `links` KEY IS ABSENT rather
      #     than `[]` -- unless STORE ITSELF sent an empty list, which is a truthful statement and
      #     is preserved. Absence says "nothing here was reported"; `[]` would assert "this entry
      #     has no links", falsely, about an entry that has links this caller may not see.
      #   * `links-continue` IS A CONTINUATION CURSOR CARRYING IDENTITIES (`i2_read.py:615-618`
      #     puts `participant`, `neighbour` and `after-link` inside it), so it is authorized by the
      #     SAME recursive continuation machinery as `omitted.continue` -- the identity-at-every-
      #     depth walk -- and is ABSENT, never null, when it cannot be emitted. It is ALSO withheld
      #     whenever ANY of that entry's links was dropped: a cursor seeded past content this
      #     caller never received would make the client's NEXT page skip readable links, which is
      #     the mis-seeded-cursor corruption `authorized_continue`'s whole-list drop already
      #     avoids.
      #   * `self-links` obey THE SAME PER-LINK RULE as an entry's `links`. They are loops on the
      #     subject, but a loop's key text still enumerates participants and K8 permits more than
      #     the subject among them.
      #   * NOTHING MARKS A DROP. No count, no marker, no eighth `omitted.bound` member, no new
      #     key: a link withheld by the ACL is indistinguishable from one STORE never sent, which
      #     is the same non-oracle property that governs a dropped entry.
      #   * A DIGEST NEVER TRAVELS WITHOUT ITS AUTHORIZED SIBLING KEY. This is the SAME pairing
      #     principle already documented at CONTINUE_PAIRED_ADDRESS_KEYS and for the same reason:
      #     STORE accepts `{"digest": <hex>}` as a participant address (`i2_read.py:474-482`), so a
      #     digest reaching a caller who may not read the card it addresses is the same
      #     read-permission oracle a leaked key is. An entry carrying a digest with no String `key`
      #     beside it is unauthorizable, so it is dropped.
      #   * `self-links` are kept only when the subject participant is authorized -- which, by
      #     construction, it is whenever a participant was emitted at all, since an unauthorized
      #     participant returns before any of this -- AND each individual self-link then passes
      #     the per-link participant rule above, because a loop's key text still enumerates every
      #     participant of that link and may name more cards than the subject.
      #   * NO `authorize` AT ALL (nil, or not callable) -> nothing structured is emitted. Absence
      #     is the fail-closed direction.
      #
      # ==== WHY THIS DOES NOT COLLIDE WITH .forward_store_metadata
      #
      # `counts` is in FORWARDED_PAYLOAD_KEYS, so both this function and .forward_store_metadata
      # can write it. They cannot disagree: this function writes `counts` ONLY from a `bucket`
      # descriptor's own `counts`, and .forward_store_metadata writes it ONLY when STORE sent a
      # TOP-LEVEL `counts`. STORE's real I2-09 and I2-03 payloads carry NO top-level `counts`
      # (measured: I2-09 top-level keys are exactly ["participant","buckets"], I2-03's exactly
      # ["entries"]), so in practice only one writes. The ASSERTION rather than the assumption:
      # when STORE DID send a top-level `counts`, this function leaves it to the forwarder and does
      # NOT overwrite it -- STORE's own top-level value wins, because it is the more authoritative
      # of the two and because silently replacing a real STORE value with a derived one is exactly
      # the substitution this lane forbids.
      #
      # @param into [Hash] the payload being built. Mutated and returned.
      # @param store_payload [Hash, nil] STORE's own payload, carried on I3ReadResult#payload.
      # @param authorize [#call, nil] STORE key text -> Boolean, under the CALLER's identity.
      # @param label_bearing [Array, nil] accepted for symmetry with the client's label
      #   intersection; NOT used to filter, because the client performs that intersection itself
      #   against `limits['label-bearing-properties']` and doing it twice could drop a label the
      #   client would have kept. Present so a future caller cannot assume it is honoured here.
      # @return [Hash] `into`.
      # @param unresolved_heads [Enumerable<String>, nil] the heads STORE ITSELF declared as
      #   unresolved-target constructors (.unresolved_heads_from_declarations). nil or empty means
      #   NO head is treated as an unresolved target and every non-Card position fails closed,
      #   which is the pre-existing behaviour. See UNRESOLVED_SIGNATURE_RESULT.
      def project_store_graph(into, store_payload, authorize:, label_bearing: nil,
                              unresolved_heads: nil)
        return into unless into.is_a?(Hash)
        return into unless store_payload.is_a?(Hash)
        # NO ACL -> NO STRUCTURED GRAPH. Fail closed, never "probably fine".
        return into unless authorize.respond_to?(:call)

        unresolved = normalized_unresolved_heads(unresolved_heads)

        if store_payload.key?("participant")
          participant = project_participant(store_payload["participant"], authorize)
          # An unauthorized or unauditable participant means NO structured graph at all: everything
          # below hangs off an identity this caller may not read.
          return into if participant.nil?

          into["participant"] = participant
        end

        if store_payload.key?("buckets")
          buckets = project_buckets(store_payload["buckets"], authorize, unresolved)
          into["buckets"] = buckets unless buckets.nil?
        end

        # The I2-03 page shape. `bucket` is STORE's own descriptor for the requested link-type;
        # it names a LINK-TYPE HEAD, not a card, so it carries no identity to authorize.
        if store_payload.key?("bucket")
          descriptor = store_payload["bucket"]
          into["bucket"] = descriptor
          # The bucket-derived counts, ONLY when STORE did not send a top-level `counts` of its
          # own (see the header: STORE's top-level value is the authoritative one and is left to
          # .forward_store_metadata).
          if descriptor.is_a?(Hash) && descriptor.key?("counts") && !store_payload.key?("counts")
            into["counts"] = descriptor["counts"]
          end
        end

        if store_payload.key?("entries")
          entries = project_entries(store_payload["entries"], authorize, unresolved)
          into["entries"] = entries unless entries.nil?
        end

        # Reached only when a participant was emitted, i.e. the subject IS authorized. The
        # self-links themselves still face the PER-LINK participant rule: a loop's key text
        # enumerates participants and may name a card besides the subject.
        if store_payload.key?("self-links") && into.key?("participant")
          self_links = project_links(store_payload["self-links"], authorize, unresolved)
          # ABSENT, NOT `[]`, when the ACL emptied the list -- unless STORE's own list was empty.
          into["self-links"] = self_links unless self_links.nil?
        end

        into
      end

      # STORE's OWN declared unresolved-target heads, read off its I2-07 declarations answer.
      #
      # NOTHING IS HARDCODED. A head qualifies only when STORE published a signature whose RESULT
      # TYPE is `Unresolved` (UNRESOLVED_SIGNATURE_RESULT) -- measured on the real reader child as
      # `{"head": "Wanted", "signature": {"arguments": ["String"], "result": "Unresolved"}}`. So
      # `Wanted` is recognised BECAUSE STORE DECLARED IT, and a deployment that declares a
      # different unresolved constructor gets that one instead with no code change. A malformed or
      # absent declarations payload yields an EMPTY set, which is the fail-closed direction.
      #
      # @param declarations_payload [Hash, nil] I2-07's payload (`{"heads" => [...]}`).
      # @return [Array<String>] declared unresolved-target heads; `[]` when none can be read.
      def unresolved_heads_from_declarations(declarations_payload)
        return [] unless declarations_payload.is_a?(Hash)

        heads = declarations_payload["heads"]
        return [] unless heads.is_a?(Array)

        heads.each_with_object([]) do |entry, kept|
          next unless entry.is_a?(Hash)

          head = entry["head"]
          next unless head.is_a?(String) && !head.empty?
          # Only a DECLARED head counts; a conflicted or undeclared one is not a contract fact.
          next unless entry["status"] == "declared"

          signature = entry["signature"]
          next unless signature.is_a?(Hash)
          next unless signature["result"] == UNRESOLVED_SIGNATURE_RESULT

          kept << head
        end
      end

      # IS EVERY IDENTITY CARRIED BY AN INBOUND CONTINUATION CURSOR READABLE BY THIS CALLER?
      #
      # THE ASYMMETRY THIS CLOSES, and it was a real hole, not a theoretical one. The OUTBOUND
      # side already refuses to emit a continuation whose anchor the caller cannot read
      # (`authorized_continue` -> #continue_identity_authorized?) -- that is what makes the
      # three-page stop correct. But the INBOUND side checked only the cursor's SUBJECT, its epoch
      # and its shape. So a caller who could read `(Card 19357)` could hand BACK a cursor whose
      # `after` anchor named `(Card 19372)` -- a card it cannot read -- and that anchor was relayed
      # VERBATIM to STORE as an order coordinate. Withholding an address on the way out while
      # accepting the same address on the way in is not a policy; the gate must hold BOTH ways.
      #
      # THE SAME WALKER AND THE SAME ACL, ASKED AGAIN. This is the PUBLIC entry point onto the
      # EXACT predicates that guard the outbound cursor -- `continue_identity_authorized?` for the
      # flat identity keys and `continue_link_key_authorized?` for `after-link`, whose link key
      # text embeds the address of EVERY participant of that link and so needs the per-link
      # participant audit rather than a flat check. Those two remain private implementation; this
      # method exists so the controller does not reach into them, and so the identity-key set has
      # exactly ONE definition (CONTINUE_IDENTITY_KEYS) shared by both directions.
      #
      # DEFAULT-DENY. A non-Hash cursor, a missing predicate, or any raise authorizes NOTHING.
      # `nil` under an identity key is permitted because §5.8's `no-such-bucket` cursor
      # legitimately names nobody; any other unrecognised shape fails the walker.
      def inbound_cursor_authorized?(after, authorize)
        return false unless after.is_a?(Hash)
        return false unless authorize.respond_to?(:call)

        identities_ok = CONTINUE_IDENTITY_KEYS.all? do |key|
          next true unless after.key?(key)

          continue_identity_authorized?(after[key], authorize)
        end
        return false unless identities_ok

        CONTINUE_LINK_KEY_KEYS.all? do |key|
          next true unless after.key?(key)

          continue_link_key_authorized?(after[key], authorize)
        end
      end

      # Build the `schema-version` + `limits` profile from STORE's own I2-01 payload.
      #
      # @param payload [Hash] I2-01's payload (`i2_read.py:710-728`).
      # @return [Hash] {"schema-version" => String, "limits" => Hash}
      # @raise [Unrenderable] when STORE's I2-01 answer is not shaped as the contract says. A
      #   malformed status answer is a refusal, not a partially-filled limits block.

      def profile_from_status_payload(payload)
        raise Unrenderable, "I2-01 payload is not a mapping" unless payload.is_a?(Hash)

        schema = payload.dig("versions", "schema")
        raise Unrenderable, "I2-01 reported no versions.schema" unless schema.is_a?(String) && !schema.strip.empty?

        page_max = payload["page-max"]
        raise Unrenderable, "I2-01 reported no page-max block" unless page_max.is_a?(Hash)

        retain = payload["state-retain"]
        raise Unrenderable, "I2-01 reported no state-retain block" unless retain.is_a?(Hash)

        limits = {}
        # Flattened from STORE's own nested blocks, every value copied, none derived.
        limits["page-max-entries"] = fetch_required!(page_max, "page-max-entries")
        limits["page-max-connections"] = fetch_required!(page_max, "page-max-connections")
        limits["page-max-bytes"] = fetch_required!(page_max, "page-max-bytes")
        limits["per-neighbour-link-max"] = fetch_required!(page_max, "per-neighbour-link-max")
        limits["refresh-max-participants"] = fetch_required!(page_max, "refresh-max-participants")
        # NO STORE SOURCE: present as a key, null as a value. See the module header.
        limits["poll-interval-ms"] = nil
        limits["fanout-limit"] = fetch_required!(payload, "fanout-limit")
        limits["state-retain-ms"] = fetch_required!(retain, "state-retain-ms")
        limits["state-retain-positions"] = fetch_required!(retain, "state-retain-positions")
        limits["label-bearing-properties"] = fetch_required!(payload, "label-bearing-properties")

        { "schema-version" => schema, "limits" => limits }
      end

      private

      # ---- THE STRUCTURED PROJECTION'S PRIVATE STEPS -------------------------------------------
      #
      # Each returns nil for "do not emit this key at all" and a value for "emit exactly this".
      # nil is NEVER rendered as JSON null by the caller: .project_store_graph tests for nil and
      # omits the key, because an absent key reports "STORE said nothing here" while a null would
      # assert a value exists and is nothing.

      # STORE's participant, with its own `key` authorized, or nil when it may not be emitted.
      #
      # Copies ONLY the sub-keys STORE sent, VERBATIM -- including `label` (whose `{name,
      # type-name}` the client reads to build its label form), `class`, `trash` (a real boolean,
      # not normalised) and `properties` (the controller re-filters that list against the atom ACL;
      # see its own note). No sub-key is added, renamed or defaulted.
      def project_participant(participant, authorize)
        return nil unless participant.is_a?(Hash)

        key = participant["key"]
        # UNAUTHORIZABLE IS UNAUTHORIZED. A non-String key cannot be mapped to a card and so cannot
        # be checked; emitting it (and its digest) would be disclosing an address this deck was
        # unable to audit.
        return nil unless key.is_a?(String)
        return nil unless authorize.call(key) == true

        participant.dup
      end

      # STORE's I2-09 `buckets` list. Each bucket names a LINK-TYPE, not a card, so the bucket
      # itself carries no identity; its `entries` / `self-links` DO, and are authorized.
      #
      # `drawn` is forwarded exactly as STORE sent it (false on every real bucket measured), because
      # it is the flag the client uses to decide whether to read `entries` at all. Flipping it would
      # change what the client ingests.
      def project_buckets(buckets, authorize, unresolved = [])
        return nil unless buckets.is_a?(Array)

        buckets.map do |bucket|
          next bucket unless bucket.is_a?(Hash)

          projected = bucket.dup
          if bucket.key?("entries")
            entries = project_entries(bucket["entries"], authorize, unresolved)
            # An unreadable entries value is DROPPED rather than emitted as null: the bucket's own
            # `drawn` flag already tells the client whether to expect entries.
            if entries.nil?
              projected.delete("entries")
            else
              projected["entries"] = entries
            end
          end
          # A BUCKET'S OWN `self-links` -- the client reads `wireBucket['self-links']`
          # (`drawn-graph.mjs:663,893`) as well as the top-level list, so the SAME per-link
          # participant rule applies here. Absent, not `[]`, when the ACL empties a non-empty list.
          if bucket.key?("self-links")
            self_links = project_links(bucket["self-links"], authorize, unresolved)
            if self_links.nil?
              projected.delete("self-links")
            else
              projected["self-links"] = self_links
            end
          end
          projected
        end
      end

      # STORE's entry list, with every entry's own `key` authorized AND every KEPT entry's links
      # authorized per-link. A denied or unauditable entry is DROPPED WHOLE -- digest, label,
      # trash, counts and links together -- and nothing records that it was dropped, so a dropped
      # entry is indistinguishable from one STORE never sent.
      # ==== AN ACL-EMPTIED LIST IS `nil` (ABSENT), NOT `[]` -- THE COMPLETE-EMPTY DEFECT
      #
      # THE DEFECT. This returned `entries.each_with_object([])`, so when the ACL denied EVERY
      # entry it returned `[]` and the caller emitted `"entries": []`. To the client that is a
      # COMPLETE AND TRUTHFUL statement -- "this bucket has no neighbours" -- about a bucket that
      # in fact has neighbours this caller may not read. The response said `ok` with an empty list
      # and no indication anything was withheld, which is precisely the silent-drop-dressed-as-fact
      # that the per-entry drop is otherwise careful to avoid: an INDIVIDUAL dropped entry is
      # indistinguishable from one STORE never sent (correct, non-oracle), but an ALL-DENIED list
      # rendered as `[]` is a POSITIVE CLAIM OF ABSENCE that is false.
      #
      # THE FIX, USING THE EXISTING ABSENCE SEMANTICS AND NO NEW VOCABULARY. An ACL-emptied
      # non-empty list returns nil -> the caller OMITS the key, exactly as `project_links` already
      # does for links and `restrict_structured_properties!` does for properties. Absent means
      # "STORE said nothing here" rather than "there is nothing here". STORE's OWN empty list is
      # still preserved verbatim, because that `[]` IS the truth.
      #
      # No marker is coined, no `bound` member is added and nothing announces the ACL: §5.8's
      # enumeration is closed at seven (`k8-draft-2.md:782-784`) and has no ACL member, so the
      # honest move is to assert nothing rather than to assert something false or to invent a word.
      def project_entries(entries, authorize, unresolved = [])
        return nil unless entries.is_a?(Array)
        # STORE's own empty list is TRUTH and travels as itself.
        return entries if entries.empty?

        kept = entries.each_with_object([]) do |entry, acc|
          next unless entry_authorized?(entry, authorize, unresolved)

          acc << project_entry_links(entry, authorize, unresolved)
        end
        # ABSENT, NOT `[]`: an ACL-emptied list must not assert that the bucket is empty.
        kept.empty? ? nil : kept
      end

      # One KEPT entry, with its `links` and `links-continue` authorized. Returns a COPY whenever
      # anything changed; STORE's own object is never mutated.
      #
      # ==== THE DEFECT THIS REPAIRS (a readable entry could disclose a DENIED THIRD PARTICIPANT)
      #
      # `entry_authorized?` authorizes the ENTRY's own `key` and nothing else. A kept entry's
      # `links[]` were then forwarded VERBATIM -- each with its own `key` AND `digest`. But a STORE
      # LINK KEY TEXT IS AN EXPRESSION THAT EMBEDS THE CARD ADDRESS OF EVERY PARTICIPANT:
      #     "(created-by (Card 2) (Card 1))"
      #     "(includes (Card 2) (Card 34) \"rich_text+description\")"
      # (measured on the real reader child), and K8 documents links with three or more participants
      # (`k8-draft-2.md:624-628`). Meanwhile the caller's authorizer maps ONLY the single documented
      # participant form `(Card <digits>)` (`i3_read_controller.rb:1040-1048`), so a LINK key is
      # UNMAPPABLE and could never be authorized -- yet it was emitted anyway. So reading one
      # permitted neighbour disclosed the address, and therefore the existence, of every other
      # participant of the joining link, including cards the ACL denies. That is the same
      # read-permission oracle the `omitted.continue` authorization closed, in a new place.
      #
      # ==== THE RULE, AND WHY IT USES ONE ACL
      #
      # The link key is AUDITED STRUCTURALLY. Its quoted DATA literals are stripped first
      # (`i2_read.py:183` emits them via `json.dumps`), its TOP-LEVEL positions after the head
      # symbol are then enumerated, and EVERY position must be exactly `(Card <digits>)` -- the one
      # form the CALLER's `authorize` predicate can map -- and must be authorized by it. Deriving a
      # `(Card N)` TEXT in order to ASK the existing ACL is authorization-only: it is the exact
      # form that predicate already maps, nothing derived is ever emitted, and no second ACL is
      # introduced here. The link -- STORE's own object, unchanged -- is emitted only when EVERY
      # position was both recognisable AND authorized.
      #
      # ==== FAIL CLOSED, IN EVERY DIRECTION
      #
      #   * ANY unauthorized `(Card <digits>)` participant -> the LINK IS DROPPED, whole: key,
      #     digest, link-type, subject-positions, neighbour-positions, copy-count, is-participant,
      #     all of it.
      #   * ANY participant position in A FORM THIS DECK CANNOT MAP TO A CARD ID -> DROPPED. This
      #     is R48-B1 and it is the narrow, true statement of what is enforced: `Card` is NOT a
      #     STORE constant (`grep -c Card i2_read.py` is ZERO; STORE fits participants over
      #     runtime-declared heads, `i2_read.py:93` / `_signature` / `_Fitter#link_members`), and
      #     K8 documents the non-Card participant form `(Wanted "k")` (`k8-draft-2.md:630`). An
      #     identity this deck cannot authorize must not be emitted, so `(Wanted ...)`,
      #     `(Unresolved ...)`, a nested link, a bare token and any future declared head all drop
      #     their link. The previous rule scanned for `(Card \d+)` GLOBALLY and rejected only the
      #     zero-match case, so a key MIXING an authorized `(Card N)` with one of these satisfied
      #     `all?` and rode out WHOLE -- disclosing that other participant.
      #   * QUOTED DATA IS DATA, NEVER A PARTICIPANT (R48-N1). A link whose string member merely
      #     CONTAINS the text `(Card 99)` -- `(links-to (Card 7) "see (Card 99) for detail")` --
      #     is NOT dropped: that text never occupies a participant position. The previous global
      #     scan treated it as one and silently OVER-REDACTED a readable link.
      #   * NO authorizable participant position in the key at all -> DROPPED. An identity form
      #     this deck cannot enumerate is one it cannot audit, and an unaudited link must not be
      #     emitted on the hope that it names nobody.
      #   * a key that is not a WELL-FORMED balanced expression, a NON-String key, a link that is
      #     not a Hash, or no `authorize` at all -> DROPPED, for the same reason.
      #   * THE ENTRY ITSELF SURVIVES a dropped link (its own key was authorized). Dropping the
      #     link rather than the entry matches the existing safe-direction precedent --
      #     `atom_from_entry!` / `filter_by_read_auth` drop an unattributable ATOM, not the read.
      #   * EVERY link dropped -> the `links` KEY IS ABSENT, not `[]`. STORE's OWN empty list is
      #     preserved as the truthful statement it is. Absent != empty.
      #   * `links-continue` is a CURSOR carrying identities (`i2_read.py:615-618` nests
      #     `participant`, `neighbour` and `after-link` in it), so it goes through the EXISTING
      #     recursive continuation authorizer -- and is withheld outright when any link was
      #     dropped, because a cursor seeded past content this caller never received would make the
      #     client's next page skip readable links.
      #   * NOTHING is coined to announce any of this.
      def project_entry_links(entry, authorize, unresolved = [])
        has_links = entry.key?("links")
        has_continue = entry.key?("links-continue")
        return entry unless has_links || has_continue

        projected = entry.dup

        dropped_any = false
        if has_links
          links = project_links(entry["links"], authorize, unresolved)
          if links.nil?
            # ABSENT, NOT `[]`: an ACL-emptied list must not assert "this entry has no links".
            projected.delete("links")
            dropped_any = true
          else
            projected["links"] = links
            dropped_any = entry["links"].is_a?(Array) && links.length != entry["links"].length
          end
        end

        if has_continue
          # A cursor past dropped content would corrupt the client's next page -> withheld whole.
          authorized = dropped_any ? nil : authorized_links_continue(entry["links-continue"], authorize)
          # ABSENT, NEVER NULL -- `links-continue: null` would assert there is nothing to continue.
          if authorized.nil?
            projected.delete("links-continue")
          else
            projected["links-continue"] = authorized
          end
        end

        projected
      end

      # STORE's link list with every link authorized against EVERY participant its key embeds, or
      # nil for "do not emit this key at all".
      #
      # nil is returned when the list is not an Array (unauditable) and when the ACL emptied a
      # NON-EMPTY STORE list. STORE's OWN empty list comes back as itself, because `[]` from STORE
      # is a truthful claim while an ACL-emptied `[]` would be a false one.
      def project_links(links, authorize, unresolved = [])
        return nil unless links.is_a?(Array)
        return links if links.empty?

        kept = links.select { |link| link_authorized?(link, authorize, unresolved) }
        kept.empty? ? nil : kept
      end

      # Is EVERY participant position of this link's key text an AUTHORIZED `(Card <digits>)`?
      #
      # See the LINK_KEY_CARD_POSITION_PATTERN header for the full argument. This is a STRUCTURAL
      # audit, not a scan: the key's quoted DATA literals are stripped first (`i2_read.py:183`),
      # then its top-level positions are enumerated, then EVERY position must be exactly the one
      # form this deck's ACL can map and must be authorized by it.
      #
      # Fail-closed on: a non-Hash link; a non-String key; a key that is not a well-formed
      # expression; a key with ZERO authorizable participants; a participant position in ANY form
      # other than `(Card <digits>)` (`(Wanted ...)` per `k8-draft-2.md:630`, `(Unresolved ...)`,
      # a nested link, a bare token, any future declared head); and any DENIED `(Card <digits>)`.
      def link_authorized?(link, authorize, unresolved = [])
        return false unless link.is_a?(Hash)
        return false unless authorize.respond_to?(:call)

        key = link["key"]
        return false unless key.is_a?(String)

        ids = link_key_card_positions(key, unresolved)
        # UNPARSEABLE, or NO ENUMERABLE PARTICIPANT, or a position this deck cannot authorize ->
        # UNAUDITABLE -> DROPPED. Not "probably harmless".
        return false if ids.nil? || ids.empty?

        # The `(Card <id>)` text is derived ONLY to ask the caller's existing ACL; it never reaches
        # the wire. STORE's own link object is what is emitted, unchanged, if all of these pass.
        ids.all? { |id| authorize.call("(Card #{id})") == true }
      end

      # The card ids of this link key's participant positions, or nil when the key cannot be
      # audited at all.
      #
      # nil means "do not emit this link": the key is not a well-formed expression, or it carries a
      # participant position in a form this deck cannot map to a card id. An EMPTY array means the
      # key parsed but named no authorizable participant, which is also a drop. Only a non-empty
      # array of ids is a key whose every participant position this module can hand to the ACL.
      # ==== A DECLARED UNRESOLVED TARGET IS AN ADMISSIBLE POSITION THAT NAMES NO CARD
      #
      # `(Wanted "k")` in a participant position used to return nil and drop the whole link. By
      # N04 (`k8-draft-2.md:630-631`) an unresolved target "belongs to its one link, has no
      # neighbourhood, and is never shared between links", so it is NOT an independent identity to
      # authorize -- it has no card, and it rides the authorization of the link that owns it. It is
      # therefore SKIPPED as a non-card position (contributing no id), while EVERY `(Card <digits>)`
      # position in the same key is still authorized as before. The link is emitted only if those
      # pass, so the target's link-scoped authorization IS its owning link's authorization.
      #
      # ONLY heads STORE declared as unresolved-target constructors qualify, and `unresolved` is
      # EMPTY unless STORE's own I2-07 declarations supplied them -- so this cannot become a
      # blanket allow for arbitrary non-Card heads, and with no declarations the behaviour is
      # byte-identical to before.
      def link_key_card_positions(key, unresolved = [])
        # A raw NUL cannot come out of STORE's key text (`json.dumps` escapes control characters),
        # so its presence means this is not a key this deck will parse. Also keeps
        # LINK_KEY_DATA_POSITION unforgeable.
        return nil if key.include?("\u0000")

        # QUOTED DATA FIRST. Each `json.dumps` literal becomes ONE data position, so nothing inside
        # it -- including a literal `(Card 99)` -- can be read as structure. This is R48-N1.
        masked = key.gsub(LINK_KEY_QUOTED_DATA_PATTERN, LINK_KEY_DATA_POSITION)
        # An unbalanced quote leaves a bare `"` behind: unparseable, so dropped.
        return nil if masked.include?('"')

        members = link_key_members(masked)
        # head + at least one position; anything shorter is not a link expression.
        return nil if members.nil? || members.length < 2

        head = members.first
        # The head is a SYMBOL, not a position. A parenthesised or data head is not a link key.
        return nil if head.include?("(") || head.include?(")") || head == LINK_KEY_DATA_POSITION

        ids = []
        members.drop(1).each do |position|
          # A stripped string literal is DATA and holds no identity.
          next if position == LINK_KEY_DATA_POSITION

          match = LINK_KEY_CARD_POSITION_PATTERN.match(position)
          if match
            ids << match[1]
            next
          end
          # A DECLARED UNRESOLVED TARGET names no card and belongs to this link (N04) -> admissible
          # as a position, contributing no identity to authorize.
          next if unresolved_target_position?(position, unresolved)

          # ANY OTHER FORM is an identity this deck cannot authorize -> the whole link is dropped.
          return nil
        end
        ids
      end

      # Is this masked participant position a DECLARED unresolved-target expression?
      #
      # Recognised ONLY as `(<declared-head> <args...>)` where `<declared-head>` is a head STORE
      # itself declared with result type `Unresolved`. The arguments are NOT inspected and nothing
      # is derived from them: this answers one question -- "is this position a non-card target that
      # belongs to its link" -- and nothing here is ever emitted.
      def unresolved_target_position?(position, unresolved)
        return false if unresolved.nil? || unresolved.empty?
        return false unless position.is_a?(String)

        members = link_key_members(position)
        # head + at least one argument; a bare `(Wanted)` is not the declared `String` form.
        return false if members.nil? || members.length < 2

        head = members.first
        return false if head.include?("(") || head.include?(")") || head == LINK_KEY_DATA_POSITION

        unresolved.include?(head)
      end

      # The declared-unresolved-head set, normalized. nil/garbage -> `[]` (fail closed).
      def normalized_unresolved_heads(heads)
        return [] unless heads.is_a?(Enumerable)

        heads.select { |h| h.is_a?(String) && !h.empty? }
      end

      # The TOP-LEVEL members of a masked key expression -- `["head", "pos", ...]` -- or nil when
      # the text is not a balanced parenthesised expression.
      #
      # Splits on top-level whitespace only, so a nested expression stays ONE member and is
      # therefore judged as one position rather than having its innards scanned.
      def link_key_members(masked)
        return nil unless masked.start_with?("(") && masked.end_with?(")") && masked.length >= 2

        members = []
        current = +""
        depth = 0
        masked[1..-2].each_char do |ch|
          case ch
          when "("
            depth += 1
            current << ch
          when ")"
            depth -= 1
            return nil if depth.negative?

            current << ch
          when " ", "\t", "\n", "\r"
            if depth.zero?
              members << current unless current.empty?
              current = +""
            else
              current << ch
            end
          else
            current << ch
          end
        end
        return nil unless depth.zero?

        members << current unless current.empty?
        members
      end

      # The entry-level `links-continue` cursor, authorized by the EXISTING recursive continuation
      # machinery, or nil when it may not be emitted.
      #
      # Reuses `continue_item_authorized?` rather than re-implementing the walk: the cursor's real
      # shape (`i2_read.py:615-618`) is `{kind, participant, bucket, neighbour, after-link, epoch,
      # position}`, which is the same class of structure `omitted.continue`'s items are, so it gets
      # the same identity-at-every-depth rules, the same CONTINUE_MAX_DEPTH ceiling, the same
      # unrecognised-key fail-closed and the same digest pairing rule.
      #
      # ==== `neighbour` AND `after-link` ARE NOW AUDITED RATHER THAN UNRECOGNISED
      #
      # THE DEFECT. Both keys were deliberately left OUT of CONTINUE_KNOWN_KEYS, which made every
      # link-level cursor an unrecognised shape and therefore DENIED. The reasoning was sound about
      # the hazard -- `neighbour` is `_order(pid, part)`, a LIST, and `after-link` is a LINK key
      # text embedding every participant of that link, so NEITHER is the flat `(Card <digits>)`
      # form the ACL maps -- but the conclusion was wrong: it treated "cannot be authorized AS A
      # FLAT IDENTITY" as "cannot be authorized AT ALL", so a readable entry whose links were
      # truncated lost its continuation unconditionally and the client could never page the rest of
      # them. A DEAD END, not a permission decision.
      #
      # THE FIX, USING AUDITS THAT ALREADY EXIST AND THE SAME ONE ACL:
      #   * `neighbour` is an IDENTITY KEY whose value is an ORDER TUPLE, authorized ELEMENT-WISE
      #     (CONTINUE_IDENTITY_KEYS) -- its participant key text faces the same predicate a
      #     top-level `participant` does;
      #   * `after-link` is a LINK KEY, authorized by the SAME per-link participant audit every
      #     emitted link goes through (CONTINUE_LINK_KEY_KEYS), so EVERY participant position it
      #     embeds must be recognisable and authorized.
      # Neither is waved through as "structural" and no second ACL is introduced. A cursor naming
      # anything this caller may not read is STILL dropped whole, and an unrecognised key anywhere
      # still fails closed.
      def authorized_links_continue(continuation, authorize)
        return nil unless authorize.respond_to?(:call)
        return nil unless continuation.is_a?(Hash)

        continue_item_authorized?(continuation, authorize) ? continuation : nil
      end

      # One entry is emittable only when its OWN `key` is a String this caller may read.
      #
      # THE PAIRING RULE, same as CONTINUE_PAIRED_ADDRESS_KEYS. A `digest` is an ADDRESS STORE
      # accepts (`i2_read.py:474-482`) and this deck cannot resolve one to a card, so a digest may
      # travel ONLY beside an authorized String `key` in the SAME entry. An entry with a digest and
      # no String key is therefore dropped -- the digest never outlives the authorization of the
      # card it addresses.
      #
      # THIS CHECKS THE ENTRY ONLY. Its `links` are authorized SEPARATELY and per-link by
      # .project_entry_links, because a link key names participants this check never looks at.
      #
      # ==== THE DECLARED UNRESOLVED TARGET: AUTHORIZED VIA ITS OWNING LINK (N04)
      #
      # THE DEFECT. An entry whose own `key` is `(Wanted "markdown+description")` was dropped,
      # because `authorize.call` maps only `(Card <digits>)` and could only answer false. The
      # caller therefore lost a genuinely readable neighbour -- STORE returned it, the subject card
      # was authorized, the joining link named only authorized cards, and the entry still vanished.
      # Worse, it vanished as the ONLY entry, so the bucket rendered as a complete-empty `[]`.
      #
      # THE RULE, TAKEN FROM THE CONTRACT RATHER THAN CHOSEN HERE. By N04 an unresolved target
      # "belongs to its one link, has no neighbourhood, and is never shared between links"
      # (`k8-draft-2.md:630-631`). It has NO card identity to authorize, so the authorization that
      # applies is its OWNING LINK's: the entry is emittable iff it HAS links and EVERY one of them
      # passes the full per-link participant audit (which authorizes every `(Card <digits>)`
      # position and recognises the declared target as a non-card position). So:
      #   * subject and link participants readable -> the target rides out, as STORE sent it;
      #   * ANY owning link denied or unauditable -> the entry is dropped WHOLE, as before;
      #   * NO links at all -> dropped: an unresolved target with no owning link contradicts N04,
      #     and an entry this deck cannot tie to an authorized link is one it must not emit.
      # This is NOT a global allow for non-Card entries: it applies ONLY to heads STORE ITSELF
      # declared with result type `Unresolved`, and `unresolved` is empty without those
      # declarations. Every other non-Card key is still denied exactly as before.
      def entry_authorized?(entry, authorize, unresolved = [])
        return false unless entry.is_a?(Hash)

        key = entry["key"]
        return false unless key.is_a?(String)

        return true if authorize.call(key) == true
        # NOT a card this caller may read. The ONE remaining admissible case is a DECLARED
        # unresolved target, authorized through the link that owns it.
        return false unless unresolved_target_position?(key, unresolved)

        links = entry["links"]
        return false unless links.is_a?(Array) && !links.empty?

        links.all? { |link| link_authorized?(link, authorize, unresolved) }
      end

      # ---- the continuation-authorization steps (unchanged) ------------------------------------

      # The `continue` list, or nil when it cannot be emitted without disclosing a denied identity.
      # ==== STORE EMITS A BARE CURSOR OBJECT, NOT ONLY A LIST (the second half of the dead end)
      #
      # THE DEFECT. This required an Array and returned nil for anything else. But §5.8 defines
      # THREE admissible `continue` item forms -- "the cursor; the list of uncovered participants;
      # and, for `no-such-bucket`, one entry per missing bucket" (`k8-draft-2.md:792-796`) -- and
      # the FIRST of those, the cursor, is what STORE actually emits on the page-out path, as a
      # BARE MAPPING:
      #     "omitted": {"bound": "entries", "count": 5,
      #                 "continue": {"kind": "entries", "participant": "(Card 19357)", ...}}
      #                                              (measured, STORE 042 seq 17/18/19)
      # So every real truncated page presented a Hash, failed the `is_a?(Array)` test, and had its
      # continuation dropped -- the SAME silent paging dead end as the order-tuple defect, reached
      # by a different route. Both had to be fixed for the chain to page at all.
      #
      # THE FIX. A Hash is treated as ONE item and authorized by the SAME per-item walk; an Array
      # is still authorized element-wise and still drops WHOLE on any unauthorized member. Nothing
      # is reshaped: whatever STORE sent is what travels, and the two forms stay distinct on the
      # wire exactly as STORE emitted them.
      def authorized_continue(continuation, authorize)
        return nil unless authorize.respond_to?(:call)

        case continuation
        when Hash
          # §5.8's FIRST form: the cursor itself, as one bare item.
          continue_item_authorized?(continuation, authorize) ? continuation : nil
        when Array
          # An empty list carries no identity and is forwarded as STORE sent it.
          return continuation if continuation.empty?

          safe = continuation.all? { |item| continue_item_authorized?(item, authorize) }
          safe ? continuation : nil
        end
      end

      # One `continue` item is emittable only when EVERY identity in it -- AT EVERY DEPTH -- is
      # authorized AND every key in it, at every depth, is one this deck recognises.
      #
      # ==== THE DEFECT THIS REPAIRS (a real read-permission leak, not a theoretical one)
      #
      # This method used to inspect ONLY the item's OWN top-level keys and never recursed. Because
      # `cursor` is an allowlisted STRUCTURAL key, an item shaped `{bucket, cursor}` passed
      # authorization WITHOUT ANY IDENTITY CHECK AT ALL -- the `CONTINUE_IDENTITY_KEYS.all?` loop
      # simply found none of its three keys present and returned true.
      #
      # And `{bucket, cursor}` is EXACTLY what STORE emits on the real neighbours page-out path:
      #     omitted["continue"].append({"bucket": h, "cursor": self._cursor(state, key, h, last)})
      #                                                               (`i2_read.py:888`)
      # where `_cursor` (`i2_read.py:695-700`) returns
      #     {"kind": "entries", "participant": subject, "bucket": head, "narrowing": None,
      #      "after": last, "epoch": state.epoch, "position": state.position}
      # So `cursor.participant` and `cursor.after` ARE participant key texts -- card identities --
      # nested one level down, and they reached the wire UNAUTHORIZED. The earlier regression test
      # covered only the FLAT `{key, digest}` shape, which is why this went unnoticed.
      #
      # ==== THE FIX: AUTHORIZE BY POSITION-IN-STRUCTURE, AT EVERY DEPTH
      #
      # The walk descends through Hashes and Arrays and applies the SAME rules at every level, so
      # `cursor.participant` is authorized by the SAME `authorize` predicate -- the SAME ACL
      # allow-set used to filter the atom list -- as a top-level `participant`. Nothing here
      # authorizes anything itself; there is still exactly one ACL and it lives in the caller.
      #
      # Every existing fail-closed property is preserved, now at every depth:
      #   * an UNRECOGNISED KEY anywhere -> unauthorized (it could be a future identity form);
      #   * a NON-STRING, NON-NULL identity -> unauthorized (it cannot be mapped to a card, so it
      #     cannot be checked, so it must not be emitted) -- including a Hash or Array found under
      #     an identity key, which is a shape this deck does not know how to read as an identity;
      #   * a PRESENT-BUT-NULL identity -> fine; it names nobody (the §5.8 `no-such-bucket` cursor);
      #   * a `digest` without an authorized sibling `key` -> unauthorized (see
      #     CONTINUE_PAIRED_ADDRESS_KEYS);
      #   * anything deeper than CONTINUE_MAX_DEPTH -> unauthorized;
      # and ANY unauthorized node drops the WHOLE continuation (the caller's rule, unchanged).
      #
      # `bound` and `count` are untouched by all of this and still forward: they carry no identity.
      # No omission vocabulary is invented, nothing is added to `omitted`, and `cursor` remains an
      # ACCEPTED key -- the change is that its CONTENTS are inspected when it is a Hash.
      def continue_item_authorized?(item, authorize)
        # A BARE STRING item is a key text with no structure to inspect; authorize it directly.
        return authorize.call(item) == true if item.is_a?(String)
        return false unless item.is_a?(Hash)

        continue_node_authorized?(item, authorize, 0)
      end

      # Authorize ONE NODE of a continuation structure, then its children. See
      # .continue_item_authorized? for the argument; this is the recursive step.
      def continue_node_authorized?(node, authorize, depth)
        # A structure too deep to finish auditing is not forwarded. Fail closed, never "probably
        # fine".
        return false if depth > CONTINUE_MAX_DEPTH

        case node
        when Hash
          return false unless node.keys.all? { |k| CONTINUE_KNOWN_KEYS.include?(k.to_s) }
          # A STORE digest may travel ONLY beside a `key` text that was authorized in this same
          # node. Checked before the per-key walk so an unpaired digest cannot be reached by any
          # other route.
          return false unless paired_addresses_backed_by_key?(node)

          node.all? do |k, v|
            if CONTINUE_IDENTITY_KEYS.include?(k.to_s)
              continue_identity_authorized?(v, authorize)
            elsif CONTINUE_LINK_KEY_KEYS.include?(k.to_s)
              # A LINK key text: audited by the per-link participant audit, not as one identity.
              continue_link_key_authorized?(v, authorize)
            else
              # A STRUCTURAL key. Its VALUE may still be a container holding identities deeper
              # down -- `cursor` is exactly that -- so descend instead of accepting it blind.
              continue_node_authorized?(v, authorize, depth + 1)
            end
          end
        when Array
          node.all? { |element| continue_node_authorized?(element, authorize, depth + 1) }
        else
          # A structural SCALAR (a bucket name, an epoch hex, a position integer, a `kind`, a
          # `narrowing`, a `reason`). It is not under an identity key, so it names no card.
          true
        end
      end

      # The value found under an identity key, at any depth.
      #
      # Accepts the TWO shapes STORE really emits, and nothing else (see CONTINUE_IDENTITY_KEYS for
      # the measured evidence and the dead-end this repairs):
      #   * a KEY TEXT        -- `"(Card 19357)"`, authorized by the caller's predicate;
      #   * an ORDER TUPLE    -- `["(Card 19360)", "", -1]`, authorized ELEMENT-WISE by this same
      #     method, so an identity nested in a tuple gets exactly the same ACL question.
      def continue_identity_authorized?(value, authorize, depth = 0)
        # A present-but-null identity (the §5.8 `no-such-bucket` cursor) names nobody.
        return true if value.nil?

        case value
        when String
          # STORE's order tuples pad unused slots with the EMPTY string, which addresses nobody.
          # Only a NON-empty text is an identity, and only it is put to the ACL.
          return true if value.empty?

          authorize.call(value) == true
        when Numeric, true, false
          # An ORDER COORDINATE (STORE's third tuple slot is `-1`). A number is not a card address:
          # there is no form in which this deck's ACL takes an integer, so it names nobody.
          true
        when Array
          # ELEMENT-WISE, with the depth ceiling still enforced so a pathological nesting cannot
          # exhaust the stack. A tuple of identities is authorized iff EVERY element is.
          return false if depth >= CONTINUE_MAX_DEPTH

          value.all? { |element| continue_identity_authorized?(element, authorize, depth + 1) }
        else
          # A Hash, or anything else, under an identity key: a shape this deck does not recognise
          # as an identity is one it must not emit. Unchanged fail-closed direction.
          false
        end
      end

      # A LINK KEY TEXT found under a continuation key (`after-link`).
      #
      # Audited by the SAME per-link participant audit every emitted link goes through, because a
      # link key embeds the address of EVERY participant of that link and so cannot be one flat
      # identity. Null names nobody; a non-String is a shape this deck cannot audit -> denied.
      def continue_link_key_authorized?(value, authorize)
        return true if value.nil?
        return false unless value.is_a?(String)
        return true if value.empty?

        link_authorized?({ "key" => value }, authorize)
      end

      # Is every STORE-digest address in this node backed by a `key` text in the SAME node?
      #
      # The digest itself is never authorized directly -- it cannot be, there is no digest -> card
      # resolver in this deck (see CONTINUE_PAIRED_ADDRESS_KEYS). Instead it rides on the
      # authorization of the sibling `key`, which the per-key walk performs. A null digest
      # addresses nobody and is fine.
      def paired_addresses_backed_by_key?(node)
        CONTINUE_PAIRED_ADDRESS_KEYS.all? do |address_key|
          next true unless node.key?(address_key)
          next true if node[address_key].nil?

          node["key"].is_a?(String)
        end
      end

      def fetch_required!(hash, key)
        raise Unrenderable, "I2-01 omitted #{key}" unless hash.key?(key)

        hash[key]
      end

      # THE NO-STATE RULE, applied in exactly one place.
      #
      # On `not ready` / `unavailable`: all three present and exactly nil -> JSON null.
      # On every other outcome: all three must come from a REAL validated STORE envelope. A
      # stateful outcome with no state source is UNRENDERABLE, because emitting nulls there is the
      # protocol violation the client rejects (`live-bridge.mjs:784-792`) and emitting invented
      # values is the fabrication this whole lane forbids.
      def state_triple(envelope:, state:, outcome:)
        if NO_STATE_OUTCOMES.include?(outcome)
          # PRESENT AND EXACTLY NULL. Not omitted, not a mix, and a known bootstrap epoch is never
          # reported here even when the carrier happens to hold one (`k8-draft-2.md:398-400`).
          return STATE_KEYS.each_with_object({}) { |k, h| h[k] = nil }
        end

        source = envelope || state
        unless source.is_a?(Hash)
          raise Unrenderable, "outcome #{outcome.inspect} requires a state triple and none was supplied"
        end

        STATE_KEYS.each_with_object({}) do |k, h|
          unless source.key?(k)
            raise Unrenderable, "outcome #{outcome.inspect} requires #{k} and STORE did not supply it"
          end
          value = source[k]
          if value.nil?
            raise Unrenderable, "outcome #{outcome.inspect} may not carry a null #{k}"
          end

          h[k] = value
        end
      end
    end
  end
end
