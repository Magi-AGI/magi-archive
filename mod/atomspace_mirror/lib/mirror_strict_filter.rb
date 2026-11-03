# frozen_string_literal: true

# The locked STRICT dataset filter for a prod-derived dev database. It is the UNION of two predicates:
#
#   A. Administrator documentation: everything under the Administrator root by left-id ancestry, except
#      the role's authorization scaffolding (names whose parts after the root are all *-settings, such as
#      Administrator+*members and Administrator+*self+*read).
#   B. READ-locked cards: the card's effective read rule resolves to a non-empty set of principals that is
#      entirely within {Administrator, Nemquae}. A rule shared with anyone else does not match.
#
# Filtering uses the denormalized effective read rule, never write rules or name/content search. An
# Administrator-value filter alone misses the doc tree, whose own rule points at another principal.
#
# The manifest is read-only and reports ids and counts only. Dependents (cards whose left or right part is
# excluded) cannot survive their parent, so they are excluded too and counted separately. A rule that cannot
# be resolved blocks apply, because guessing could keep a private card. Codenamed system cards are never
# excluded, because the deck cannot run without them; they are reported so a human can look at them.
#
# apply! deletes rows, so it demands the live database name as confirmation and refuses a DB with mirror
# tables or an active gate. Run it only on a disposable or staged copy. Attachment blobs live outside the
# database: the manifest lists their cards for separate removal. Credentials are handled separately.
module MirrorStrictFilter
  ROOT_NAME = "Administrator"
  LOCK_PRINCIPALS = %w[Administrator Nemquae].freeze

  class Refused < StandardError; end

  Manifest = Struct.new(:ancestry_ids, :read_locked_ids, :dependent_ids, :excluded_ids, :scaffold_ids,
                        :unresolved_rule_ids, :attachment_card_ids, :cascade, :protected_system_ids,
                        keyword_init: true) do
    def to_h_report
      { ancestry: ancestry_ids.size, read_locked: read_locked_ids.size, dependents: dependent_ids.size,
        excluded_total: excluded_ids.size, trashed_excluded: Card.where(id: excluded_ids, trash: true).count,
        scaffold_kept: scaffold_ids.size, unresolved_rule_ids: unresolved_rule_ids,
        protected_system_ids: protected_system_ids,
        attachment_card_ids: attachment_card_ids, cascade: cascade, excluded_ids: excluded_ids }
    end
  end

  module_function

  def manifest(conn: ActiveRecord::Base.connection)
    root = Card.where(key: ROOT_NAME.downcase, trash: false).pick(:id) ||
           raise(Refused, "no #{ROOT_NAME} root card found")
    ancestry, scaffold = ancestry_split(root, conn)
    locked, unresolved = read_locked(conn)
    locked -= scaffold
    locked.delete(root)
    candidates = (ancestry + locked).uniq
    protected_ids = codenamed(candidates)
    base = candidates - protected_ids
    dependents = dependents_of(base, conn, keep: scaffold + [root])
    protected_dependents = codenamed(dependents)
    dependents -= protected_dependents
    excluded = (base + dependents).uniq.sort
    Manifest.new(ancestry_ids: ancestry.sort, read_locked_ids: locked.sort, dependent_ids: dependents.sort,
                 excluded_ids: excluded, scaffold_ids: scaffold.sort, unresolved_rule_ids: unresolved.sort,
                 attachment_card_ids: attachment_cards(excluded), cascade: cascade_counts(excluded, conn),
                 protected_system_ids: (protected_ids + protected_dependents).sort)
  end

  def apply!(confirm_db:, conn: ActiveRecord::Base.connection)
    live = conn.current_database
    raise Refused, "confirmation #{confirm_db.inspect} does not match database #{live.inspect}" unless confirm_db == live

    MirrorRuntimeGuards.assert_refresh_precondition!(conn: conn)
    plan = manifest(conn: conn)
    raise Refused, "unresolved read rules: #{plan.unresolved_rule_ids.join(',')}" if plan.unresolved_rule_ids.any?

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
    scaffold = ids.select { |id| scaffold?(id, root) }
    [ids - scaffold, scaffold]
  end

  # Every part after the root is a *-setting: this card is authorization structure, not documentation.
  def scaffold?(id, root)
    parts = []
    current = Card.where(id: id).pick(:left_id, :right_id)
    while current
      left, right = current
      parts << Card.where(id: right).pick(:key)
      break if left == root

      current = left && Card.where(id: left).pick(:left_id, :right_id)
    end
    parts.compact.any? && parts.all? { |key| key.to_s.start_with?("*") }
  end

  def read_locked(conn)
    rule_ids = conn.select_values("SELECT DISTINCT read_rule_id FROM cards WHERE read_rule_id IS NOT NULL").map(&:to_i)
    matching = []
    unresolved = []
    Card::Auth.as_bot do
      rule_ids.each do |rule_id|
        principals = rule_principals(rule_id)
        if principals.nil?
          unresolved << rule_id
        elsif principals.any? && (principals - LOCK_PRINCIPALS).empty?
          matching << rule_id
        end
      end
    end
    ids = matching.empty? ? [] : conn.select_values("SELECT id FROM cards WHERE read_rule_id IN (#{matching.join(',')})")
    [ids.map(&:to_i), unresolved]
  end

  # nil means it could not be resolved. A card-less rule id must not read as an empty, harmless rule.
  def rule_principals(rule_id)
    rule = Card.fetch(rule_id, look_in_trash: true)
    return nil unless rule

    rule.include_set_modules
    rule.item_names.map(&:to_s)
  rescue StandardError
    nil
  end

  def dependents_of(ids, conn, keep:)
    found = []
    frontier = ids
    until frontier.empty?
      list = frontier.join(",")
      rows = conn.select_values("SELECT id FROM cards WHERE left_id IN (#{list}) OR right_id IN (#{list})").map(&:to_i)
      frontier = rows - ids - found - keep
      found.concat(frontier)
    end
    found
  end

  def codenamed(ids)
    return [] if ids.empty?

    Card.where(id: ids).where.not(codename: nil).pluck(:id)
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
