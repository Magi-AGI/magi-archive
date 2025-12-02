# Spoiler Search functionality for Butterfly Galaxii
# Card: Games+Butterfly Galaxii+GM Docs+Spoiler Search

# Add class methods to Card if not already present
unless Card.respond_to?(:find_player_spoilers)
  class Card
    class << self
      def find_player_spoilers(spoiler_terms)
        results = {}
        
        spoiler_terms.each do |term|
          all_matches = Card.search(match: term)
          
          player_visible = all_matches.select do |card|
            (card.name.start_with?("Games+Butterfly Galaxii+Player") ||
             card.name.start_with?("Games+Butterfly Galaxii+AI")) &&
            !card.name.include?("+GM")
          end
          
          results[term] = player_visible if player_visible.any?
        end
        
        results
      end
      
      def spoiler_context(card, term, context_chars = 50)
        content = card.content.to_s.gsub(/<[^>]+>/, '').strip
        return nil if content.empty?
        
        match_index = content.downcase.index(term.downcase)
        return nil unless match_index
        
        start_pos = [0, match_index - context_chars].max
        end_pos = [content.length, match_index + term.length + context_chars].min
        
        snippet = content[start_pos...end_pos]
        snippet = "...#{snippet}" if start_pos > 0
        snippet = "#{snippet}..." if end_pos < content.length
        
        snippet
      end
    end
  end
end

# Custom content view for this card
def content
  terms_card = fetch(trait: :spoiler_terms)
  
  if !terms_card ||!terms_card.real?
    return "<p><em>No spoiler terms configured. Edit the +spoiler terms card.</em></p>"
  end
  
  # Parse terms from content (one per line in list items)
  content_text = terms_card.content.to_s
  spoiler_terms = content_text.scan(/<li>(.*?)<\/li>/m).flatten.map(&:strip).reject(&:empty?)
  
  if spoiler_terms.empty?
    return "<p><em>Spoiler terms list is empty.</em></p>"
  end
  
  results = Card.find_player_spoilers(spoiler_terms)
  render_spoiler_results(results, spoiler_terms.count)
end

def render_spoiler_results(results, total_terms)
  if results.empty?
    <<-HTML
      <div style="padding: 20px; background-color: #e8f5e9; border-left: 4px solid #4caf50; margin: 10px 0;">
        <h2 style="color: #2e7d32; margin-top: 0;">✓ No Spoilers Detected</h2>
        <p>Searched #{total_terms} spoiler term(s). No matches in Player or +AI sections.</p>
      </div>
    HTML
  else
    total_matches = results.values.flatten.count
    
    output = <<-HTML
      <div style="padding: 20px; background-color: #ffebee; border-left: 4px solid #f44336; margin: 10px 0;">
        <h2 style="color: #c62828; margin-top: 0;">⚠️ Potential Spoilers Found</h2>
        <p><strong>#{total_matches} match(es)</strong> found for #{results.keys.count} term(s).</p>
      </div>
    HTML
    
    results.each do |term, cards|
      output += <<-HTML
        <div style="margin: 20px 0; padding: 15px; background-color: #fff3e0; border-left: 3px solid #ff9800;">
          <h3 style="margin-top: 0;">Term: "#{ERB::Util.html_escape(term)}" — #{cards.count} match(es)</h3>
          <ul>
      HTML
      
      cards.each do |card|
        output += "<li>[[#{card.name}]]"
        
        if context = Card.spoiler_context(card, term)
          output += "<br><em style='color: #666; font-size: 0.9em;'>#{ERB::Util.html_escape(context)}</em>"
        end
        
        output += "</li>"
      end
      
      output += "</ul></div>"
    end
    
    output
  end
end
