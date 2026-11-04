# frozen_string_literal: true

# Resolves a card's read rule from persisted data alone, so a gate's verdict cannot depend on what the process has
# already looked at. The answer is Decko's own: permission_rule_id_and_class(:read) is what the set_read_rule event
# stores. Only the cache state it runs in is defined here.
#
# Why that is needed (card-1.110.0, logs/impl9/p27_first_placeholder.log):
#
#   1. lib/card/lexicon.rb:102-108  id_to_lex stores lex => id with no trash check. So reading the name of a trashed
#      card, or of anything under it, points a [left_id, right_id] lex at the trashed row even when a live card has the
#      same lex. Dev and prod both hold such twins (8097 live, 8116 trashed).
#   2. lib/card/lexicon.rb:112-118  a by-name lookup under that live card now walks through the trashed id, finds
#      nothing, and returns nil.
#   3. lib/card/fetch/store.rb:21-28  Fetch caches a new-card placeholder for what is a real card.
#   4. lib/card/name/all/parts.rb:17-19, lib/card/set/pattern/all.rb:27-29  left_or_new then builds a new left card, and
#      a new card has no *self pattern, so its own +*self+*read rule is skipped and the deck default comes back.
#   5. lib/card/cache/temporary.rb:80-87  all of this lasts until a temporary cache passes MAX_KEYS and wipes itself,
#      so where the evictions fall in a scan decides the answer.
#
# A row that inherits through _left from such a card then resolves the open default rather than its real rule. A stale
# open column looks correct and a correct column looks stale, and repair_permissions! would write the wrong value.
#
# So each resolution here starts from empty temporary caches, on a private cache set that has no shared store:
#   - A row's answer can then only depend on rows, not on which rows were read before it or by whom.
#   - The caller's caches are neither read nor changed. Cards a reader is served from are looked at separately.
module MirrorReadRuleResolver
  LEX_TO_ID_PREFIX = "L-"

  module_function

  # Runs the block on a private, temporary-only cache set, then puts the caller's caches back untouched.
  def isolated
    @trashed_ids = nil
    saved_shared = Card::Cache.instance_variable_get(:@shared_cache)
    saved_caches = Card::Cache.instance_variable_get(:@cache_by_class)
    Card::Cache.instance_variable_set(:@shared_cache, false)
    Card::Cache.instance_variable_set(:@cache_by_class, {})
    yield
  ensure
    Card::Cache.instance_variable_set(:@shared_cache, saved_shared)
    Card::Cache.instance_variable_set(:@cache_by_class, saved_caches)
    @trashed_ids = nil
  end

  # Lexicon keys of the trashed rows, read once per isolated run.
  def trashed_ids
    @trashed_ids ||= Card.where(trash: true).pluck(:id).to_set(&:to_s)
  end

  # Empties what a lookup can get wrong: every cached card and placeholder, and every lex => id entry. Inside isolated,
  # that is everything a resolution reads, apart from two things kept for speed because no lookup can distort them:
  #   - the id => name or lex entries of live rows, each of which restates one row. A trashed row's entry goes too: finding
  #     it decides whether id_to_lex rewrites the lex, so keeping it would let scan order reach a trashed row's answer.
  #   - the RULES table, built by one query over the rule rows (lib/card/rule/cache.rb), and reloaded for no other reason.
  def cold!
    rules_key = Card::Rule::Cache.cache_key
    rules = Card.cache.temp.read(rules_key)
    lexicon = Card::Lexicon.cache.temp
    Card::Cache.cache_by_class.each_value { |cache| cache.temp.reset unless cache.temp.equal?(lexicon) }
    trashed = trashed_ids
    lexicon.store.delete_if { |key, _value| key.start_with?(LEX_TO_ID_PREFIX) || trashed.include?(key) }
    Card.cache.temp.store[rules_key] = rules if rules
  end

  # Ready for a resolution from a cold cache. Call inside isolated, on a card loaded from its row.
  def prepare(card)
    cold!
    card.reset_patterns
    card.include_set_modules
    card
  end

  # [read_rule_id, read_rule_class] as Decko's set_read_rule event would store them for this row.
  def read_rule(card)
    prepare(card).permission_rule_id_and_class(:read)
  end
end
