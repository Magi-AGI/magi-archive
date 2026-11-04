# frozen_string_literal: true

require "time" # Time#iso8601 (stdlib; autoloaded under Decko/ActiveSupport but not standalone)

# Level 1 -- pure encoder. Converts one Decko card action into the ordered atom-event list for a
# single mirror_outbox row's payload. No model writes; reads the action's already-loaded card +
# associations (references_out, card_changes) and the injected pre_state / auth / request_context.
# Referentially transparent: same inputs -> identical output.
#
# Output wire format is FROZEN in Card 17161 (L1 "Slice 2 outbox payload wire format", 2026-06-21);
# atom shapes per Canonical Encodings. V1 only -- Content is the raw db_content string, NO cardtype
# dispatch (Section 7), except on a credential-bearing card, where it is the Redacted sentinel symbol.
#
# Input contract (verified against Decko card-1.110.0 on dev 2026-06-15):
#   action          : Card::Action -- #id, #action_type (:create|:update|:delete), #draft,
#                     #super_action_id, #card_id, #act, #card_changes, #card
#   action.act      : Card::Act    -- #id, #actor_id, #acted_at (#ip_address deliberately unread, D-5)
#   action.card     : Card         -- the 14 source attributes; #references_out (Card::Reference)
#   card_changes    : Card::Change -- #field (TRACKED_FIELDS name OR integer index), #value (new)
#   pre_state       : Hash{field_name => old_value} for the changes array (string or symbol keys);
#                     {} when unavailable
#   auth            : Hash{current_id:, as_id:} -- Source-5 dual-actor snapshot captured at action
#                     time by L2 (Card::Auth.serialize.current_id / .as_id); {} -> JSON null
#   request_context : Hash of the 4 Source-6 agent fields; {} outside an MCP request (-> JSON null)
module CardAtomEncoder
  module_function

  SOURCE = "decko"
  EVENT_SCHEMA_VERSION = "decko-spaceevent-v1"
  STAGE = "integrate_with_delay"

  # Raised for genuine corrupt action DATA (e.g. an unknown card_changes.field). The L2 writer
  # catches THIS narrowly to emit a terminal 'failed' outbox row; unexpected errors (NoMethodError
  # etc.) propagate loudly. auth-contract violations stay ArgumentError (a caller bug, not data).
  class EncodingError < StandardError; end

  # Decko card_changes.field is an integer index into this list (Card::Change#field maps it to the
  # name); the encoder accepts either the integer index or the name string.
  TRACKED_FIELDS = %w[name type_id db_content trash left_id right_id].freeze

  # Right parts that hold credential material, by codename, so a renamed card still counts. On the data this has run against only
  # password, salt, api_key and secret_key have a codename. The others match once one exists; until then the containers below catch
  # them. secret_key is *recaptcha settings+secret key, which is readable by default and which no name-based sanitizer pattern catches.
  CREDENTIAL_CODENAMES = %w[password salt api_key token reset_token key_hash metadata secret_hash secret_key].freeze

  # Everything under these holds client secrets or key hashes, whatever its right part is called: see CARD_PREFIX in the gem's
  # oauth/client_cards.rb and CONTAINER_NAME in mcp_api's mcp/api_key_manager.rb. Neither has a codename on the data this has run
  # against, so today the name is what matches. Names, not keys: Decko derives the keys (mcp_o_auth_client, mcp_api_key).
  CREDENTIAL_CONTAINERS = ["MCP OAuth Clients", "MCP API Keys"].freeze
  CREDENTIAL_CONTAINER_CODENAMES = %w[mcp_oauth_clients mcp_api_keys].freeze

  # Does this card hold credential material? If so its value never leaves this encoder: Content and the db_content change carry the
  # Redacted sentinel, and the atom keeps its shape, because DriftReconciler hashes the Postgres side with this same encoder.
  # Pure: reads the card's identity and the process's codename table, never db_content, so no message can ever carry the value.
  def credential_bearing?(card)
    codename_in?(card.right_id, CREDENTIAL_CODENAMES) ||
      codename_in?(card.left_id, CREDENTIAL_CONTAINER_CODENAMES) ||
      under_credential_container?(card.name)
  end

  def encode(action, pre_state: {}, auth:, request_context: {}, card: nil)
    # auth is MANDATORY (Source-5 dual-actor audit data): callers must pass the Card::Auth.serialize
    # snapshot, or { current_id: nil, as_id: nil } when genuinely unavailable. Omission must be
    # explicit, never a silent null -- so no default, and the keys must be present.
    unless auth.is_a?(Hash) && auth.key?(:current_id) && auth.key?(:as_id)
      raise ArgumentError, "auth: must be a Hash with :current_id and :as_id keys"
    end
    return [] if action.draft

    card ||= action.card
    [decko_card(card),
     *decko_references(card),
     decko_provenance(action, card, pre_state || {}, auth || {}, request_context || {})]
  end

  # Bulk-load snapshot of a card's CURRENT state for the Section 1 bootstrap sweep: DeckoCard + its
  # DeckoReferences, with NO DeckoProvenance (the sweep is one bulk operation, not N per-action
  # events; run metadata lives in mirror_bootstrap_runs). PATCH-4 faithful -- identical atom shapes
  # to the forward path, just without the provenance companion. Pure: no action/auth needed; takes a
  # live Card (the sweep encodes current state, not an action). Drafts/trash are the caller's call --
  # the sweep iterates `Card.where(trash: [true, false])`.
  def encode_card_snapshot(card)
    [decko_card(card), *decko_references(card)]
  end

  # CURRENT-state snapshot for a synthetic RECONCILE event (Section 3 / Level 6) -- the payload of a
  # `reconcile:card:C:R` mirror_outbox row created by the L6 Reconciler for a PG-but-not-Space card, a
  # mismatched-hash card, or a hook-lag Case (b) hold. UNLIKE encode_card_snapshot (bulk_load, no
  # provenance), a reconcile event is DRAINED through the forward /apply path, and the L8 drain
  # validator requires EXACTLY ONE DeckoProvenance whose event_id/card_id/action_id match the outbox
  # row (mirror_drain_validator validate_identity!). A reconcile event has no real Card::Action, so we
  # synthesize one provenance atom: action_id is NIL (a reconcile row's action_id is NULL by the OQ#12
  # CHECK), action = :reconcile, stage = "reconcile", changes = [] (a full-state overwrite, not a
  # field delta). `actor` is the reconcile run's operator id and `acted_at` the run timestamp -- the
  # only audit fields a synthetic event can honestly carry; the request-time dual-actor + agent
  # context have no source and serialize as JSON null. Pure: takes a live Card (current state).
  #
  # actor_id is the provenance DeckoActor field, which is a Decko actor INTEGER in the forward path --
  # so it must be an Integer or nil here too. A reconcile run's human/operator attribution is a STRING
  # and belongs in mirror_reconcile_runs.actor / the run report, NOT in this integer atom field;
  # passing a string would silently change the type/meaning of actor_id, so it's rejected loudly.
  def encode_reconcile_snapshot(card, event_id:, actor_id: nil, acted_at: nil)
    unless actor_id.nil? || actor_id.is_a?(Integer)
      raise ArgumentError, "actor_id: must be an Integer (Decko actor id) or nil; put string operator " \
                           "attribution in mirror_reconcile_runs.actor, not the provenance actor_id field"
    end
    [decko_card(card),
     *decko_references(card),
     reconcile_provenance(card, event_id: event_id, actor_id: actor_id, acted_at: acted_at)]
  end

  def decko_card(card)
    atom "DeckoCard", [
      ["Id",        card.id],
      ["Name",      card.name],
      ["Key",       card.key],
      ["Codename",  card.codename.present? ? sym(card.codename) : sym("NoCodename")],
      ["TypeId",    card.type_id],
      ["TypeName",  card.type_name],
      ["LeftId",    card.left_id || sym("NoLeft")],
      ["RightId",   card.right_id || sym("NoRight")],
      ["Content",   credential_bearing?(card) ? sym("Redacted") : card.db_content],
      ["Trash",     card.trash ? true : false],
      ["CreatedAt", iso(card.created_at)],
      ["UpdatedAt", iso(card.updated_at)],
      ["CreatorId", card.creator_id],
      ["UpdaterId", card.updater_id]
    ]
  end

  def decko_references(card)
    Array(card.references_out).map do |r|
      atom "DeckoReference", [
        ["RefererId",  r.referer_id],
        ["RefereeKey", r.referee_key],
        ["RefereeId",  r.referee_id || sym("Unresolved")],
        ["RefType",    sym(r.ref_type)],
        # IsPresent = does the reference resolve to an existing card. The card_references
        # is_present column is DEAD in card-1.110.0 (0/574 rows populated on dev, 2026-06-21 L2b),
        # so it is derived from referee_id (the resolved target id; nil => a wanted/unresolved link).
        ["IsPresent",  !r.referee_id.nil?]
      ]
    end
  end

  def decko_provenance(action, card, pre_state, auth, ctx)
    atom "DeckoProvenance", [
      ["source",               SOURCE],
      ["event_schema_version", EVENT_SCHEMA_VERSION],
      ["event_id",             "decko:action:#{action.id}"],
      ["action_id",            action.id],
      ["act_id",               action.act.id],
      ["super_action_id",      action.super_action_id || sym("NoSuper")],
      ["action",               sym(action.action_type.to_s)],
      ["draft",                action.draft ? true : false],
      ["card_id",              action.card_id],
      ["card_key",             card.key],
      ["actor_id",             action.act.actor_id],
      ["auth_current_id",      auth[:current_id]],   # Source-5 dual-actor (Card::Auth.serialize),
      ["auth_as_id",           auth[:as_id]],        # captured at action time by L2; JSON null if absent
      ["acted_at",             iso(action.act.acted_at)],
      ["ip_address",           sym("NoIP")],                # D-5: never store the editor's IP
      ["stage",                STAGE],
      ["changes",              changes(action, pre_state, card)],
      ["agent_session_id",     ctx[:agent_session_id]],
      ["agent_kind",           ctx[:agent_kind] ? sym(ctx[:agent_kind].to_s) : nil],
      ["origin_system",        ctx[:origin_system] ? sym(ctx[:origin_system].to_s) : nil],
      ["origin_request_id",    ctx[:origin_request_id]]
    ]
  end

  # Synthetic provenance companion for a reconcile event. Carries the SAME 21-field ordered shape as
  # decko_provenance (so the sidecar decoder handles both uniformly) -- only the values differ: a NULL
  # action_id/act_id, the `reconcile` action marker, the `reconcile` stage, an empty `changes`, and
  # JSON null for every request-time field that a synthetic event cannot source. The three identity
  # fields the drain validator checks (event_id, card_id, action_id) match the reconcile outbox row.
  def reconcile_provenance(card, event_id:, actor_id:, acted_at:)
    atom "DeckoProvenance", [
      ["source",               SOURCE],
      ["event_schema_version", EVENT_SCHEMA_VERSION],
      ["event_id",             event_id],
      ["action_id",            nil],                 # reconcile rows carry a NULL action_id (OQ#12 CHECK)
      ["act_id",               nil],
      ["super_action_id",      sym("NoSuper")],
      ["action",               sym("reconcile")],    # synthetic marker (vs create/update/delete)
      ["draft",                false],
      ["card_id",              card.id],
      ["card_key",             card.key],
      ["actor_id",             actor_id],            # Decko actor INTEGER (nil if the run has no Decko-user context)
      ["auth_current_id",      nil],                 # no request-time auth snapshot for a synthetic event
      ["auth_as_id",           nil],
      ["acted_at",             iso(acted_at)],
      ["ip_address",           sym("NoIP")],
      ["stage",                "reconcile"],         # vs "integrate_with_delay"
      ["changes",              []],                  # full-state overwrite, no field-level delta
      ["agent_session_id",     nil],
      ["agent_kind",           nil],
      ["origin_system",        nil],
      ["origin_request_id",    nil]
    ]
  end

  def changes(action, pre_state, card)
    credential = credential_bearing?(card)
    Array(action.card_changes).map do |ch|
      field = field_name(ch.field)
      if credential && field == "db_content"
        { "field" => field, "old" => sym("Redacted"), "new" => sym("Redacted") }
      else
        { "field" => field, "old" => pre_lookup(pre_state, field), "new" => ch.value }
      end
    end
  end

  # --- helpers ---

  # Card is absent only in the standalone specs, where the card is a double. A real card always comes with the codename table.
  def codename_in?(id, codenames)
    return false if id.nil? || !defined?(::Card::Codename)

    codenames.include?(::Card::Codename[id].to_s)
  end

  # A descendant, not the container itself, and only at the top of the name: "Notes+MCP API Keys+x" is not under it.
  def under_credential_container?(name)
    top, rest = name.to_s.split("+", 2)
    !rest.nil? && CREDENTIAL_CONTAINERS.any? { |container| container.casecmp?(top) }
  end

  # Card::Change#field may be the name string or the raw integer index -- normalize to a name and
  # validate it against the locked TRACKED_FIELDS set. A corrupt/unknown field (out-of-range index
  # OR an unexpected name) raises rather than encoding a bogus change -- this surfaces any new Decko
  # tracked field for a deliberate contract update instead of leaking it silently (Codex 2026-06-21).
  def field_name(raw)
    name = raw.is_a?(Integer) && (0...TRACKED_FIELDS.size).cover?(raw) ? TRACKED_FIELDS[raw] : raw.to_s
    return name if TRACKED_FIELDS.include?(name)

    raise EncodingError, "unknown/corrupt card_changes.field #{raw.inspect} (not in TRACKED_FIELDS)"
  end

  # pre_state old-value lookup, tolerant of string or symbol keys (distinguishes absent from nil).
  def pre_lookup(pre_state, field)
    return nil unless pre_state
    return pre_state[field] if pre_state.key?(field)

    pre_state[field.to_sym]
  end

  def atom(kind, fields)
    { "atom" => kind, "fields" => fields }
  end

  # A MeTTa symbol / sentinel (vs a string value). The Lane B sidecar renders {"sym" => x} as a
  # MeTTa symbol and native JSON values as MeTTa literals.
  def sym(name)
    { "sym" => name.to_s }
  end

  def iso(time)
    time&.utc&.iso8601
  end

end
