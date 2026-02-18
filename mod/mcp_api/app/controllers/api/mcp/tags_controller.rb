# frozen_string_literal: true

module Api
  module Mcp
    class TagsController < BaseController
      # GET /api/mcp/tags
      # List all tags in the system
      def index
        limit = [params.fetch(:limit, 100).to_i, 500].min
        offset = params.fetch(:offset, 0).to_i

        # Find all cards tagged as tags or with +tag structure
        all_tags = Card::Auth.as(current_account.name) do
          # Option 1: Cards with type containing 'tag' (case insensitive)
          # Option 2: Cards ending in +tags pattern
          # For now, look for cards with 'tag' in the type name
          tags_by_type = Card.where("type_id IN (SELECT id FROM cards WHERE name ILIKE '%tag%')")
                            .where.not(trash: true)
                            .limit(limit)
                            .offset(offset)
                            .to_a

          # Also check for common tag patterns like +tags pointer cards
          tag_pointers = Card.where("name LIKE '%+tags'")
                           .where.not(trash: true)
                           .limit(limit)
                           .offset(offset)
                           .to_a

          (tags_by_type + tag_pointers).uniq
        end

        total = Card::Auth.as(current_account.name) do
          Card.where("type_id IN (SELECT id FROM cards WHERE name ILIKE '%tag%')")
              .where.not(trash: true)
              .count
        end

        render json: {
          tags: all_tags.map { |tag| format_tag_summary(tag) },
          total: total,
          limit: limit,
          offset: offset,
          next_offset: (offset + limit < total ? offset + limit : nil)
        }
      end

      # GET /api/mcp/tags/:tag_name/cards
      # Get all cards tagged with a specific tag
      def cards
        tag_name = params[:tag_name]
        limit = [params.fetch(:limit, 50).to_i, 100].min
        offset = params.fetch(:offset, 0).to_i

        # Find the tag card
        tag_card = Card::Auth.as(current_account.name) do
          Card.fetch(tag_name, new: {})
        end

        if tag_card.nil? || !tag_card.id
          return render json: {
            tag_name: tag_name,
            cards: [],
            total: 0,
            limit: limit,
            offset: offset
          }
        end

        # Find cards that reference this tag
        # This could be through +tags pointer cards or direct references
        tagged_cards = Card::Auth.as(current_account.name) do
          # Method 1: Find cards with +tags pointers that reference this tag
          tag_refs = Card.where("content LIKE ?", "%[[#{tag_name}]]%")
                        .where("name LIKE '%+tags'")
                        .to_a

          # Get the left (parent) cards of these +tags cards
          parent_ids = tag_refs.map(&:left_id).compact
          Card.where(id: parent_ids)
              .where.not(trash: true)
              .limit(limit)
              .offset(offset)
              .to_a
        end

        total = Card::Auth.as(current_account.name) do
          tag_refs = Card.where("content LIKE ?", "%[[#{tag_name}]]%")
                        .where("name LIKE '%+tags'")
                        .to_a
          parent_ids = tag_refs.map(&:left_id).compact
          Card.where(id: parent_ids).where.not(trash: true).count
        end

        render json: {
          tag_name: tag_name,
          cards: tagged_cards.map { |c| format_card_summary(c) },
          total: total,
          limit: limit,
          offset: offset,
          next_offset: (offset + limit < total ? offset + limit : nil)
        }
      end

      # POST /api/mcp/tags/suggest
      # Suggest tags for a card based on content
      def suggest
        content = params[:content]
        card_name = params[:card_name]
        limit = [params.fetch(:limit, 10).to_i, 20].min

        # If card_name provided, fetch its content
        if card_name.present?
          card = Card::Auth.as(current_account.name) do
            Card.fetch(card_name)
          end
          content = card&.content if card
        end

        return render_error("validation_error", "Missing content or card_name parameter") if content.blank?

        # Simple tag suggestion based on content analysis
        # Extract potential tags from content
        suggestions = Card::Auth.as(current_account.name) do
          # Find existing tags that match words in the content
          words = content.downcase.scan(/\w+/).uniq
          
          # Look for tag cards that match content words
          matching_tags = Card.where("type_id IN (SELECT id FROM cards WHERE name ILIKE '%tag%')")
                             .where.not(trash: true)
                             .to_a
                             .select { |tag| words.any? { |word| tag.name.downcase.include?(word) } }
                             .take(limit)

          matching_tags
        end

        render json: {
          suggestions: suggestions.map { |tag| format_tag_summary(tag) },
          count: suggestions.size,
          limit: limit
        }
      end

      private

      def format_tag_summary(tag)
        {
          name: tag.name,
          id: tag.id,
          type: tag.type_name,
          updated_at: tag.updated_at.iso8601
        }
      end

      def format_card_summary(card)
        {
          name: card.name,
          id: card.id,
          type: card.type_name,
          updated_at: card.updated_at.iso8601
        }
      end
    end
  end
end
