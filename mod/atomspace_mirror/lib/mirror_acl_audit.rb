# frozen_string_literal: true

# Post-restore ACL-cache audit (SPEC 8.7, N-9). Every read re-evaluates card.ok?(:read) against the
# cached cards.read_rule_id / read_rule_class, and Decko's repair_all_permissions only fixes NULLs, so
# restored descendants need their cache compared with Decko's own resolution. Reports ids and counts
# only. A card that cannot be evaluated counts against a clean result, so the audit fails closed.
module MirrorAclAudit
  Result = Struct.new(:checked, :mismatched_ids, :error_ids, keyword_init: true) do
    def clean? = mismatched_ids.empty? && error_ids.empty?

    def to_h_report
      { checked: checked, mismatched: mismatched_ids.size, errors: error_ids.size,
        mismatched_ids: mismatched_ids, error_ids: error_ids }
    end
  end

  module_function

  def audit(scope: Card.where(trash: false))
    result = Result.new(checked: 0, mismatched_ids: [], error_ids: [])
    Card::Auth.as_bot do
      scope.find_each do |card|
        result.checked += 1
        check(card, result)
      end
    end
    result
  end

  # update_columns only: creates no card actions, so it produces no mirror events.
  def repair!(ids)
    Card::Auth.as_bot do
      Card.where(id: ids).find_each do |card|
        card.include_set_modules
        card.repair_permissions!
      end
    end
  end

  def check(card, result)
    card.include_set_modules
    computed = card.permission_rule_id_and_class(:read)
    result.mismatched_ids << card.id unless [card.read_rule_id, card.read_rule_class] == computed
  rescue StandardError
    result.error_ids << card.id
  end
  private_class_method :check
end
