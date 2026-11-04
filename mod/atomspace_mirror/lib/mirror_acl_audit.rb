# frozen_string_literal: true

require_relative "mirror_read_rule_resolver"

# Post-restore ACL-cache audit (SPEC 8.7, N-9). Every read re-evaluates card.ok?(:read) against the
# cached cards.read_rule_id / read_rule_class, and Decko's repair_all_permissions only fixes NULLs, so
# restored descendants need their cache compared with Decko's own resolution. Reports ids and counts
# only. A card that cannot be evaluated counts against a clean result, so the audit fails closed.
#
# The verdict is a function of the rows and, for stale_fetch, of what the shared store holds. It does not depend on
# what this process has already read: every row resolves from a cold, private cache (MirrorReadRuleResolver).
#
# stale_fetch_ids are rows whose columns are right while the copy a reader would be served is not, which is what
# Decko's cross-process shared cache can hold after a repair. Only that store is inspected. A process's temporary cache
# serves nobody else, and the audit's own reads no longer go near it. With no shared store there is nothing to inspect:
# the report says so in shared_cache_checked, because that is an unasked question rather than a clean answer.
module MirrorAclAudit
  Result = Struct.new(:checked, :mismatched_ids, :stale_fetch_ids, :error_ids, :trashed_divergence_ids,
                      :shared_cache_checked, keyword_init: true) do
    def clean? = mismatched_ids.empty? && stale_fetch_ids.empty? && error_ids.empty?

    # Everything repair! has to touch, including rows whose columns are right but whose cached copy is not.
    def repair_ids = mismatched_ids | stale_fetch_ids

    def to_h_report
      { checked: checked, mismatched: mismatched_ids.size, stale_fetch: stale_fetch_ids.size, errors: error_ids.size,
        mismatched_ids: mismatched_ids, stale_fetch_ids: stale_fetch_ids, error_ids: error_ids,
        trashed_divergence: Array(trashed_divergence_ids).size,
        trashed_divergence_ids: Array(trashed_divergence_ids),
        shared_cache_checked: shared_cache_checked == true }
    end
  end

  module_function

  # S-1. Selection resolves effective read rules over trashed AND untrashed rows, so the audit that
  # repairs the cache before selection must cover the same scope. Bootstrap and MirrorStrictFilter
  # both include trash: a trash: false default would leave trashed rows unrepaired.
  #
  # A trashed row's divergence is reported SEPARATELY and does not count against clean?. A trashed
  # card's rule card is trashed with it, so Decko resolves the deck default for the card while the
  # cache still holds the real rule: no repair can make those agree, and counting it as a mismatch
  # would make the audit (and every gate that depends on it) fail permanently on any deck that has
  # ever deleted a privately-ruled card. MirrorStrictFilter reads such a card's own +*self+*read
  # directly, so the divergence cannot hide a private card from selection.
  def audit(scope: Card.where(trash: [false, true]))
    served = Card::Cache[Card].shared
    result = Result.new(checked: 0, mismatched_ids: [], stale_fetch_ids: [], error_ids: [], trashed_divergence_ids: [],
                        shared_cache_checked: !served.nil?)
    MirrorReadRuleResolver.isolated do
      Card::Auth.as_bot do
        scope.find_each do |card|
          result.checked += 1
          check(card, result, served)
        end
      end
    end
    result
  end

  # update_columns only: creates no card actions, so it produces no mirror events. update_columns does not touch the
  # card cache and every read goes through Card.fetch, so without the expire a repaired card stays readable by whoever
  # the old rule allowed. Measured on dev: 34/34 columns right, 0/34 fetches right, anonymous still 200.
  #
  # Each value comes from a cold resolution, because a warm one can write the open deck default onto a protected row.
  # The expire is outside isolated because the copies readers are served are in the caller's caches.
  def repair!(ids)
    Card::Auth.as_bot do
      MirrorReadRuleResolver.isolated do
        Card.where(id: ids).find_each { |card| MirrorReadRuleResolver.prepare(card).repair_permissions! }
      end
      Card.where(id: ids).find_each do |card|
        card.include_set_modules
        card.expire
      end
    end
  end

  def check(card, result, served)
    computed = MirrorReadRuleResolver.read_rule(card)
    if [card.read_rule_id, card.read_rule_class] == computed
      result.stale_fetch_ids << card.id if served_copy_stale?(card, computed, served)
    elsif card.trash
      result.trashed_divergence_ids << card.id
    else
      result.mismatched_ids << card.id
    end
  rescue StandardError
    result.error_ids << card.id
  end
  private_class_method :check

  # The rule on the copy a reader is served is what ok?(:read) enforces. Comparing it directly also works under as_bot,
  # where ok?(:read) itself is always true. A placeholder for a real row is stale too: a reader would be told the card
  # does not exist, and a left_or_new through it skips the card's own rule. A trashed card is not served, and an absent
  # copy means the next reader loads the row, so neither has anything to compare.
  def served_copy_stale?(card, computed, served)
    return false if served.nil? || card.trash

    copy = served.read(card.key)
    return false if copy.nil?

    copy.new_card? || [copy.read_rule_id, copy.read_rule_class] != computed
  end
  private_class_method :served_copy_stale?
end
