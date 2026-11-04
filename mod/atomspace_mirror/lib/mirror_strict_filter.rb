# frozen_string_literal: true

require_relative "mirror_read_rule_resolver"

# The locked STRICT dataset filter for a prod-derived dev database. It is the UNION of two predicates:
#
#   A. Administrator documentation: everything under the Administrator root by left-id ancestry, except
#      the role's authorization scaffolding (an enumerated set of ACL/role settings, such as
#      Administrator+*members and Administrator+*self+*read; see SCAFFOLD_SETTING_CODENAMES).
#   B. READ-locked cards: the card's effective read rule resolves to a non-empty set of principals
#      that is entirely within {administrator, nemquae} by Card::Name#key. A rule shared with anyone
#      else does not match. A trashed card has no usable effective rule, so its own last known rule
#      stands in for it (see read_classification).
#
# Filtering uses the effective read rule that Decko itself resolves, never write rules and never
# name/content search. An Administrator-value filter alone misses the doc tree, whose own rule points at
# another principal.
#
# S-1/S-2 (selection fidelity): the denormalized cards.read_rule_id column is NOT the filter. A restore
# can leave it stale, and Decko's own repair only fixes NULLs. A LIVE card is decided by its effective
# rule alone: excluding it on a stale cache or a trashed self-rule would remove a card the locked policy
# keeps. A TRASHED card's effective rule collapses to *all+*read, so it is decided by its cached rule
# and its own +*self+*read instead. Disagreements between the three are reported
# (stale_read_cache_ids, verdict_disagreement_ids), and a stale live cache is refused by apply!
# (assert_audited_read_cache!). NULL-cached rows are classified like any other row and counted
# explicitly instead of being dropped from the candidate set.
#
# S-3 (unresolved refusal): rule_principals distinguishes "no rule card" (:absent) from "resolution
# raised" (:error) and never collapses either into a harmless empty rule. manifest reports both, and
# both block apply!.
#
# S-4 (references): only predicates A and B select cards. A retained card that references an excluded
# one through left_id, right_id, type_id or read_rule_id is NOT excluded for that: the locked policy keeps
# it. It cannot survive the delete either, so it is reported in dependency_conflict_ids and apply! refuses
# until someone decides. The filter never widens the exclusion by itself. The one exception is trash: a
# trashed card named after an excluded card is trash of excluded data, which the policy includes.
#
# S-5 (protected cards): codenamed system cards are never deleted, because the deck cannot run without
# them. A codenamed card the policy says to EXCLUDE is a protected-card/privacy conflict: it is
# reported with its codename and apply! refuses unless every such id is acknowledged explicitly.
#
# Every effective rule and rule verdict is resolved from a cold, private cache (MirrorReadRuleResolver). A warm scan can
# resolve the open deck default for a card whose real rule is locked, which here would retain a card the policy excludes.
#
# The manifest is read-only and reports ids, codenames and counts only -- never card content.
#
# apply! deletes rows, so it demands the live database name as confirmation and refuses a DB with
# mirror tables or an active gate. Run it only on a disposable or staged copy. Attachment blobs live
# outside the database: the manifest lists their cards for separate removal. Credentials (+*account and
# its email/password/salt/api-key fields) are NOT retained as scaffolding here; they are sanitized by
# the separate credential pass.
module MirrorStrictFilter
  ROOT_NAME = "Administrator"

  # Key-normalized (Card::Name#key) lock principals. Decko resolves +*read by key, so a lower-case
  # [[administrator]] names the same principal and must not read as a third party.
  LOCK_PRINCIPAL_KEYS = %w[administrator nemquae].freeze

  # Policy (A) authorization scaffolding, enumerated by Decko CODENAME rather than "any *-name".
  # Codenames are the stable identity: cards.key is singularized by Decko (the `members` setting has
  # key `*member`, `type_plus_right` has key `*type_plu_right`), so matching on key is both unstable
  # and, for an unknown deck, silently wrong. Set anchors, permission settings and role/membership
  # identity only. Deliberately absent: `account` (credentials are sanitized separately) and every
  # documentation/presentation setting (help, structure, default, guide, title...).
  SCAFFOLD_SETTING_CODENAMES = %w[
    self right type type_plus_right all all_plus star rstar
    read create update delete
    members roles
  ].freeze

  # ACL scaffolding is structural, not prose. A documentation-typed card under a *-suffix chain is
  # documentation, so it stays excluded.
  SCAFFOLD_TYPE_KEYS = %w[list pointer set].freeze

  class Refused < StandardError; end

  Manifest = Struct.new(:ancestry_ids, :read_locked_ids, :trash_derivative_ids, :excluded_ids, :scaffold_ids,
                        :unresolved_rule_ids, :unresolved_rule_errors, :unresolved_card_ids,
                        :stale_read_cache_ids, :null_read_cache_ids, :verdict_disagreement_ids,
                        :trashed_cache_divergence_ids,
                        :dangling_type_ids, :dangling_read_rule_ids, :dangling_part_ids,
                        :scaffold_conflict_ids,
                        :attachment_card_ids, :cascade, :protected_system_ids,
                        :protected_system_codenames,
                        keyword_init: true) do
    def unresolved? = unresolved_rule_ids.any? || unresolved_rule_errors.any? || unresolved_card_ids.any?
    def dangling? = dangling_type_ids.any? || dangling_read_rule_ids.any? || dangling_part_ids.any?

    # Retained cards that reference an excluded card. The policy keeps them; the delete cannot.
    def dependency_conflict_ids = (dangling_type_ids + dangling_read_rule_ids + dangling_part_ids).uniq.sort

    def to_h_report
      { ancestry: ancestry_ids.size, read_locked: read_locked_ids.size, trash_derivatives: trash_derivative_ids.size,
        dependency_conflict: dependency_conflict_ids.size, dependency_conflict_ids: dependency_conflict_ids,
        excluded_total: excluded_ids.size, trashed_excluded: Card.where(id: excluded_ids, trash: true).count,
        scaffold_kept: scaffold_ids.size,
        unresolved_rule_ids: unresolved_rule_ids, unresolved_rule_errors: unresolved_rule_errors,
        unresolved_card_ids: unresolved_card_ids,
        stale_read_cache: stale_read_cache_ids.size, stale_read_cache_ids: stale_read_cache_ids,
        null_read_cache: null_read_cache_ids.size, null_read_cache_ids: null_read_cache_ids,
        verdict_disagreement: verdict_disagreement_ids.size,
        verdict_disagreement_ids: verdict_disagreement_ids,
        trashed_cache_divergence: trashed_cache_divergence_ids.size,
        trashed_cache_divergence_ids: trashed_cache_divergence_ids,
        dangling_type_ids: dangling_type_ids, dangling_read_rule_ids: dangling_read_rule_ids,
        dangling_part_ids: dangling_part_ids, scaffold_conflict_ids: scaffold_conflict_ids,
        protected_system_ids: protected_system_ids,
        protected_system_codenames: protected_system_codenames,
        attachment_card_ids: attachment_card_ids, cascade: cascade, excluded_ids: excluded_ids }
    end
  end

  module_function

  def manifest(conn: ActiveRecord::Base.connection)
    root = Card.where(key: ROOT_NAME.downcase, trash: false).pick(:id) ||
           raise(Refused, "no #{ROOT_NAME} root card found")
    ancestry, scaffold = ancestry_split(root, conn)
    read = read_classification(conn)
    locked = read[:locked] - scaffold - [root]
    candidates = (ancestry + locked).uniq
    protected_ids = codenamed(candidates)
    base = candidates - protected_ids
    keep = (scaffold + [root] + protected_ids).uniq
    derivatives = trash_derivatives_of(base, conn, keep: keep)
    protected_derivatives = codenamed(derivatives)
    derivatives -= protected_derivatives
    excluded = (base + derivatives).uniq.sort
    all_protected = (protected_ids + protected_derivatives).sort
    Manifest.new(
      ancestry_ids: ancestry.sort, read_locked_ids: locked.sort, trash_derivative_ids: derivatives.sort,
      excluded_ids: excluded, scaffold_ids: scaffold.sort,
      unresolved_rule_ids: read[:absent_rule_ids].sort, unresolved_rule_errors: read[:rule_errors],
      unresolved_card_ids: read[:card_errors].keys.sort,
      stale_read_cache_ids: read[:stale_ids].sort, null_read_cache_ids: read[:null_ids].sort,
      verdict_disagreement_ids: read[:disagreement_ids].uniq.sort,
      trashed_cache_divergence_ids: read[:trashed_divergence_ids].uniq.sort,
      dangling_type_ids: dangling(excluded, conn, "type_id"),
      dangling_read_rule_ids: dangling(excluded, conn, "read_rule_id"),
      dangling_part_ids: dangling_parts(excluded, conn),
      scaffold_conflict_ids: scaffold_conflicts(scaffold, root, conn),
      attachment_card_ids: attachment_cards(excluded), cascade: cascade_counts(excluded, conn),
      protected_system_ids: all_protected,
      protected_system_codenames: codename_map(all_protected)
    )
  end

  def apply!(confirm_db:, ack_protected: nil, conn: ActiveRecord::Base.connection)
    live = conn.current_database
    raise Refused, "confirmation #{confirm_db.inspect} does not match database #{live.inspect}" unless confirm_db == live

    MirrorRuntimeGuards.assert_refresh_precondition!(conn: conn)
    plan = manifest(conn: conn)
    refuse_unresolved!(plan)
    assert_audited_read_cache!(plan: plan, conn: conn)
    refuse_dangling!(plan)
    refuse_unacknowledged_protected!(plan, ack_protected)

    ids = plan.excluded_ids
    conn.transaction do
      next if ids.empty?

      list = ids.join(",")
      actions = "SELECT id FROM card_actions WHERE card_id IN (#{list})"
      conn.execute("DELETE FROM card_changes WHERE card_action_id IN (#{actions})")
      acts = conn.select_values("SELECT DISTINCT card_act_id FROM card_actions WHERE card_id IN (#{list})").compact
      conn.execute("DELETE FROM card_actions WHERE card_id IN (#{list})")
      conn.execute("DELETE FROM card_references WHERE referer_id IN (#{list}) OR referee_id IN (#{list})")
      conn.execute("DELETE FROM card_virtuals WHERE left_id IN (#{list}) OR right_id IN (#{list})")
      if acts.any?
        conn.execute("DELETE FROM card_acts WHERE id IN (#{acts.join(',')}) " \
                     "AND NOT EXISTS (SELECT 1 FROM card_actions a WHERE a.card_act_id = card_acts.id)")
      end
      conn.execute("DELETE FROM cards WHERE id IN (#{list})")
    end
    Card::Cache.reset_all if defined?(Card::Cache)
    plan
  end

  # S-1. The runner must repair the ACL cache over trashed AND untrashed rows BEFORE manifest/apply.
  # This is the code-side half of that requirement: selection refuses to proceed while any cached
  # read rule still disagrees with Decko's own resolution.
  def assert_audited_read_cache!(plan: nil, conn: ActiveRecord::Base.connection)
    plan ||= manifest(conn: conn)
    return plan if plan.stale_read_cache_ids.empty?

    raise Refused, "read-rule cache is not audited: #{plan.stale_read_cache_ids.size} cards disagree " \
                   "with Decko's resolution (#{plan.stale_read_cache_ids.first(20).join(',')}); run " \
                   "REPAIR=1 mirror_refresh:acl_audit over trash:[false,true] before selection"
  end

  def refuse_unresolved!(plan)
    return unless plan.unresolved?

    raise Refused, "unresolved read rules: absent=#{plan.unresolved_rule_ids.join(',')} " \
                   "errors=#{plan.unresolved_rule_errors.inspect} " \
                   "cards=#{plan.unresolved_card_ids.join(',')}"
  end

  def refuse_dangling!(plan)
    raise Refused, "scaffolding conflict: #{plan.scaffold_conflict_ids.join(',')}" if plan.scaffold_conflict_ids.any?
    return unless plan.dangling?

    raise Refused, "dangling references would survive: type_id=#{plan.dangling_type_ids.join(',')} " \
                   "read_rule_id=#{plan.dangling_read_rule_ids.join(',')} " \
                   "parts=#{plan.dangling_part_ids.join(',')}"
  end

  # S-5. A codenamed card the policy says to exclude is a protected-card/privacy conflict, not a
  # silent retention. Every id must be acknowledged by the operator before apply! will run.
  def refuse_unacknowledged_protected!(plan, ack_protected)
    return if plan.protected_system_ids.empty?

    acked = Array(ack_protected).map(&:to_i).sort
    return if acked == plan.protected_system_ids

    raise Refused, "protected system cards match the exclusion policy and are retained: " \
                   "#{plan.protected_system_codenames.inspect}; pass ack_protected with exactly " \
                   "those ids to accept the retention"
  end

  # Transitive left-id closure from the root, trash included, split into docs and role scaffolding.
  def ancestry_split(root, conn)
    rows = conn.select_rows(<<~SQL)
      WITH RECURSIVE tree AS (
        SELECT id, right_id FROM cards WHERE left_id = #{root.to_i}
        UNION ALL
        SELECT c.id, c.right_id FROM cards c JOIN tree t ON c.left_id = t.id
      ) SELECT id FROM tree
    SQL
    ids = rows.flatten.map(&:to_i)
    scaffold = ids.select { |id| scaffold?(id, root, conn) }
    [ids - scaffold, scaffold]
  end

  # S-6. Policy (A) retains authorization structure, not "anything with a *-name". Every part after the
  # root must be one of the enumerated ACL/role settings BY CODENAME, AND the card itself must carry a
  # structural ACL type. A documentation body that happens to sit under a *-suffix chain stays excluded,
  # and an unrecognized or codename-less setting is NOT scaffolding -- scaffold is subtracted from the
  # exclusion set, so anything this method accepts is RETAINED. It fails closed by design.
  def scaffold?(id, root, conn = ActiveRecord::Base.connection)
    return false unless SCAFFOLD_TYPE_KEYS.include?(type_key(id, conn))

    parts = suffix_codenames(id, root, conn)
    return false if parts.nil? || parts.empty?

    parts.all? { |codename| SCAFFOLD_SETTING_CODENAMES.include?(codename.to_s) }
  end

  # The right-part CODENAMES between the card and the root, root-exclusive. nil when the chain does not
  # reach the root (a card that is not a descendant cannot be the root's scaffolding). A right part with
  # no codename yields nil in the list, which scaffold? rejects: an unnamed setting is not enumerated
  # authorization structure.
  def suffix_codenames(id, root, conn)
    parts = []
    current = conn.select_rows("SELECT left_id, right_id FROM cards WHERE id = #{id.to_i}").first
    seen = {}
    while current
      left, right = current.map { |v| v&.to_i }
      return nil if left.nil? || seen[left]

      seen[left] = true
      parts << conn.select_value("SELECT codename FROM cards WHERE id = #{right.to_i}") if right
      break if left == root.to_i

      current = conn.select_rows("SELECT left_id, right_id FROM cards WHERE id = #{left}").first
      return nil if current.nil?
    end
    parts
  end

  # Retained scaffolding whose own left parent is neither the root nor other scaffolding: a hole
  # through which excluded data could be smuggled back in.
  def scaffold_conflicts(scaffold, root, conn)
    return [] if scaffold.empty?

    allowed = scaffold + [root.to_i]
    conn.select_rows("SELECT id, left_id FROM cards WHERE id IN (#{scaffold.join(',')})")
        .reject { |_id, left| allowed.include?(left.to_i) }
        .map { |id, _left| id.to_i }.sort
  end

  def type_key(id, conn)
    conn.select_value("SELECT t.key FROM cards c JOIN cards t ON t.id = c.type_id WHERE c.id = #{id.to_i}")
  end

  # S-1/S-2/S-7. Classify by the card's read rule over every row in the database, including trash and
  # including NULL-cached rows. Three resolutions exist:
  #
  #   * effective  -- what Decko resolves right now. This IS the policy's "effective READ" for a live card,
  #                   but a trashed card's effective rule collapses to the deck default (*all+*read).
  #   * cached     -- cards.read_rule_id/read_rule_class. Survives trashing, but a restore can leave it stale.
  #   * self rule  -- the card's own +*self+*read, trash included. Survives both, absent for most cards.
  #
  # A live card is locked if its effective rule is locked, and only then. A trashed card is locked if its
  # cached rule or its own self rule is locked, because those are all that remain of its real rule. Where
  # any of the three disagree the card id is recorded in verdict_disagreement_ids, never silently reconciled.
  def read_classification(conn)
    cached = conn.select_rows("SELECT id, read_rule_id, read_rule_class, trash FROM cards")
                 .to_h { |id, rid, rcls, trash| [id.to_i, [rid&.to_i, rcls, trash]] }
    self_rules = self_read_rule_ids(conn)
    state = { locked: [], stale_ids: [], null_ids: [], absent_rule_ids: [], rule_errors: {},
              card_errors: {}, verdicts: {}, disagreement_ids: [], trashed_divergence_ids: [] }
    MirrorReadRuleResolver.isolated do
      Card::Auth.as_bot do
        # Cached rule ids are resolved too: a cached id with no rule card is an unresolved
        # classification and must block apply!, even when the effective rule is fine.
        cached.values.map(&:first).compact.uniq.each { |rule_id| rule_verdict(rule_id, state) }
        cached.each do |card_id, (rule_id, rule_class, trash)|
          classify_card(card_id, rule_id, rule_class, trash, self_rules[card_id], state)
        end
      end
    end
    state
  end

  # card_id => the id of its own "<name>+*self+*read" rule card, by codename join, trash included.
  def self_read_rule_ids(conn)
    read_id = conn.select_value("SELECT id FROM cards WHERE codename = 'read'")
    self_id = conn.select_value("SELECT id FROM cards WHERE codename = 'self'")
    return {} if read_id.nil? || self_id.nil?

    conn.select_rows(<<~SQL).to_h { |card_id, rule_id| [card_id.to_i, rule_id.to_i] }
      SELECT anchor.left_id, rule.id
      FROM cards rule
      JOIN cards anchor ON anchor.id = rule.left_id
      WHERE rule.right_id = #{read_id.to_i} AND anchor.right_id = #{self_id.to_i}
        AND anchor.left_id IS NOT NULL
    SQL
  end

  def classify_card(card_id, cached_rule_id, cached_rule_class, trashed, self_rule_id, state)
    state[:null_ids] << card_id if cached_rule_id.nil?
    card = Card.where(id: card_id).take
    return state[:card_errors][card_id] = "NotFound" unless card

    effective_id, effective_class = MirrorReadRuleResolver.read_rule(card)
    record_cache_divergence(card_id, [cached_rule_id, cached_rule_class],
                            [effective_id, effective_class], trashed, state)
    return state[:card_errors][card_id] = "NoEffectiveReadRule" if effective_id.nil?

    verdicts = [effective_id, cached_rule_id, self_rule_id].compact.uniq
                                                           .map { |rid| rule_verdict(rid.to_i, state) }
    decided = verdicts.select { |v| %i[locked shared].include?(v) }
    state[:disagreement_ids] << card_id if decided.uniq.size > 1
    deciding = truthy?(trashed) ? [cached_rule_id, self_rule_id] : [effective_id]
    state[:locked] << card_id if deciding.compact.any? { |rid| rule_verdict(rid.to_i, state) == :locked }
  rescue StandardError => e
    state[:card_errors][card_id] = e.class.name
  end

  # S-1. A cached rule that disagrees with Decko's resolution is a stale cache the operator must repair
  # before selection -- but only for a LIVE row. A trashed card's rule card is trashed with it, so
  # Decko resolves the deck default for it and no repair can ever make the two agree: treating that as
  # "unaudited" would make apply! refuse forever on any deck that has ever deleted a private card.
  # Trashed divergences are therefore reported in their own bucket, and the union (which reads the
  # trashed card's own +*self+*read) is what keeps such a card excluded.
  def record_cache_divergence(card_id, cached, effective, trashed, state)
    return if cached == effective

    if truthy?(trashed)
      state[:trashed_divergence_ids] << card_id
    else
      state[:stale_ids] << card_id
    end
  end

  def truthy?(value)
    [true, "t", "true", 1, "1"].include?(value)
  end

  # :locked, :shared, :absent or :error for a rule id, memoized.
  def rule_verdict(rule_id, state)
    return state[:verdicts][rule_id] if state[:verdicts].key?(rule_id)

    status, value = rule_principals(rule_id)
    verdict =
      case status
      when :absent
        state[:absent_rule_ids] << rule_id
        :absent
      when :error
        state[:rule_errors][rule_id] = value
        :error
      else
        value.any? && (value - LOCK_PRINCIPAL_KEYS).empty? ? :locked : :shared
      end
    state[:verdicts][rule_id] = verdict
  end

  # S-3/S-7. [:ok, key-normalized principals] | [:absent, nil] | [:error, "ExceptionClass"].
  # "No rule card" and "resolution failed" are different facts: neither may read as an empty,
  # harmless rule.
  def rule_principals(rule_id)
    rule = begin
      MirrorReadRuleResolver.cold!
      Card.fetch(rule_id, look_in_trash: true)
    rescue StandardError => e
      return [:error, e.class.name]
    end
    return [:absent, nil] unless rule

    rule.include_set_modules
    [:ok, rule.item_names.map { |name| name.to_name.key }]
  rescue StandardError => e
    [:error, e.class.name]
  end

  # S-4. Trash named after an excluded card is trash of excluded data, so it goes too, transitively. Live
  # cards are never taken this way, and a trashed card that only points at an excluded type or read rule
  # is not named after it: both are left for the conflict report.
  def trash_derivatives_of(ids, conn, keep:)
    return [] if ids.empty?

    found = []
    frontier = ids
    until frontier.empty?
      list = frontier.join(",")
      rows = conn.select_values(
        "SELECT id FROM cards WHERE trash AND (left_id IN (#{list}) OR right_id IN (#{list}))"
      ).map(&:to_i)
      frontier = rows - ids - found - keep
      found.concat(frontier)
    end
    found
  end

  def dangling(excluded, conn, column)
    return [] if excluded.empty?

    list = excluded.join(",")
    (conn.select_values("SELECT id FROM cards WHERE #{column} IN (#{list})").map(&:to_i) - excluded).sort
  end

  def dangling_parts(excluded, conn)
    return [] if excluded.empty?

    list = excluded.join(",")
    (conn.select_values("SELECT id FROM cards WHERE left_id IN (#{list}) OR right_id IN (#{list})")
         .map(&:to_i) - excluded).sort
  end

  def codenamed(ids)
    return [] if ids.empty?

    Card.where(id: ids).where.not(codename: nil).pluck(:id)
  end

  def codename_map(ids)
    return {} if ids.empty?

    Card.where(id: ids).where.not(codename: nil).pluck(:id, :codename).to_h { |id, cn| [id, cn.to_s] }
  end

  def attachment_cards(ids)
    return [] if ids.empty?

    types = [Card.where(key: "file").pick(:id), Card.where(key: "image").pick(:id)].compact
    Card.where(id: ids, type_id: types).pluck(:id).sort
  end

  def cascade_counts(ids, conn)
    return { cards: 0 } if ids.empty?

    list = ids.join(",")
    count = ->(sql) { conn.select_value(sql).to_i }
    { cards: ids.size,
      card_actions: count.call("SELECT COUNT(*) FROM card_actions WHERE card_id IN (#{list})"),
      card_changes: count.call("SELECT COUNT(*) FROM card_changes WHERE card_action_id IN " \
                               "(SELECT id FROM card_actions WHERE card_id IN (#{list}))"),
      card_references: count.call("SELECT COUNT(*) FROM card_references WHERE referer_id IN (#{list}) OR referee_id IN (#{list})"),
      card_virtuals: count.call("SELECT COUNT(*) FROM card_virtuals WHERE left_id IN (#{list}) OR right_id IN (#{list})") }
  end
end
