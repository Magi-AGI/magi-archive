# Butterfly Galaxii Spoiler Detection
# Auto-loaded by Decko when placed in mod/*/lib/card/

class Card
  class << self
    # Search for spoiler terms in player-visible cards
    # @param spoiler_terms [Array<String>] List of spoiler terms to search for
    # @return [Hash] Hash mapping spoiler terms to arrays of matching cards
    def find_player_spoilers(spoiler_terms)
      results = {}
      
      spoiler_terms.each do |term|
        # Search across all cards for this term
        all_matches = Card.search(match: term)
        
        # Filter to player-visible only:
        # - Must be under Games+Butterfly Galaxii+Player OR Games+Butterfly Galaxii+AI
        # - Must NOT contain +GM anywhere in the name
        player_visible = all_matches.select do |card|
          (card.name.start_with?("Games+Butterfly Galaxii+Player") ||
           card.name.start_with?("Games+Butterfly Galaxii+AI")) &&
          !card.name.include?("+GM")
        end
        
        # Only include term in results if matches were found
        results[term] = player_visible if player_visible.any?
      end
      
      results
    end
    
    # Extract context snippet around a matched term in card content
    # @param card [Card] The card containing the term
    # @param term [String] The search term to find
    # @param context_chars [Integer] Number of characters before/after to show
    # @return [String, nil] Context snippet or nil if not found
    def spoiler_context(card, term, context_chars = 50)
      # Strip HTML tags from content
      content = card.content.to_s.gsub(/<[^>]+>/, '').strip
      return nil if content.empty?
      
      # Find term (case insensitive)
      match_index = content.downcase.index(term.downcase)
      return nil unless match_index
      
      # Extract context around the match
      start_pos = [0, match_index - context_chars].max
      end_pos = [content.length, match_index + term.length + context_chars].min
      
      snippet = content[start_pos...end_pos]
      
      # Add ellipsis if we're not at the start/end
      snippet = "...#{snippet}" if start_pos > 0
      snippet = "#{snippet}..." if end_pos < content.length
      
      snippet
    end
  end
end
