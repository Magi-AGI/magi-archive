# frozen_string_literal: true

module Api
  module Mcp
    class CardsController < BaseController
      before_action :set_card, only: [:show, :update, :destroy, :children]
      before_action :check_admin_role!, only: [:destroy]

      # GET /api/mcp/cards
      # Search/list cards with filters
      def index
        query = build_search_query
        limit = [(params[:limit] || 50).to_i, 100].min
        offset = (params[:offset] || 0).to_i

        cards = execute_search(query, limit, offset)
        total = count_search_results(query)

        render json: {
          cards: cards.map { |c| card_summary_json(c) },
          total: total,
          limit: limit,
          offset: offset,
          next_offset: (offset + limit < total ? offset + limit : nil)
        }
      end

      # GET /api/mcp/cards/:name
      # Get single card with full content
      def show
        return render_forbidden_gm_content unless can_view_card?(@card)

        render json: card_full_json(@card)
      end

      # POST /api/mcp/cards
      # Create new card
      def create
        name = params[:name]
        return render_error("validation_error", "Missing name") unless name

        type_name = params[:type]
        return render_error("validation_error", "Missing type") unless type_name

        type_card = find_type_by_name(type_name)
        return render_error("not_found", "Type '#{type_name}' not found") unless type_card

        content = prepare_content(params[:content], params[:markdown_content])

        # Create card with service account permissions
        card = Card::Auth.as(current_account.name) do
          Card.create!(
            name: name,
            type_id: type_card.id,
            content: content
          )
        end

        render json: card_full_json(card), status: :created
      rescue ActiveRecord::RecordInvalid => e
        render_error("validation_error", "Card validation failed", { errors: e.record.errors.full_messages })
      end

      # PATCH /api/mcp/cards/:name
      # Update existing card
      def update
        unless can_modify_card?(@card)
          return render_forbidden_gm_content
        end

        Card::Auth.as(current_account.name) do
          if params[:patch]
            apply_patch(@card, params[:patch])
          else
            content = prepare_content(params[:content], params[:markdown_content])
            @card.content = content if content
            @card.save!
          end
        end

        render json: card_full_json(@card)
      rescue ActiveRecord::RecordInvalid => e
        render_error("validation_error", "Update failed", { errors: e.record.errors.full_messages })
      rescue ArgumentError => e
        render_error("validation_error", e.message)
      end

      # DELETE /api/mcp/cards/:name
      # Delete card (admin only)
      def destroy
        Card::Auth.as(current_account.name) do
          @card.delete!
        end

        render json: { status: "deleted", name: @card.name }, status: :ok
      rescue StandardError => e
        render_error("delete_failed", "Could not delete card", { error: e.message })
      end

      # GET /api/mcp/cards/:name/children
      # List children cards
      def children
        unless can_view_card?(@card)
          return render_forbidden_gm_content
        end

        # Fetch children with proper permission context
        children_cards = Card::Auth.as(current_account.name) do
          @card.children.select { |c| c.ok?(:read) }
        end

        render json: {
          parent: @card.name,
          children: children_cards.map { |c| card_summary_json(c) },
          child_count: children_cards.size
        }
      end

      # POST /api/mcp/cards/batch
      # Batch create/update operations
      def batch
        ops = params[:ops] || []
        return render_error("validation_error", "Missing ops array") if ops.empty?
        return render_error("validation_error", "Too many operations", { max: 100 }) if ops.size > 100

        mode = params[:mode] || "per_item"
        results = []

        if mode == "transactional"
          Card.transaction do
            results = process_batch_ops(ops)
            raise ActiveRecord::Rollback if results.any? { |r| r[:status] == "error" }
          end
        else
          results = process_batch_ops(ops)
        end

        # Return 207 Multi-Status if mixed results
        status = results.all? { |r| r[:status] == "ok" } ? :ok : 207
        render json: { results: results }, status: status
      end

      private

      def set_card
        name = params[:name]
        @card = Card.fetch(name, skip_modules: true)

        unless @card
          render_error("not_found", "Card '#{name}' not found", {}, status: :not_found)
          return false # Abort execution
        end

        true
      end

      def check_admin_role!
        unless current_role == "admin"
          render_forbidden("Only admin role can delete cards")
          return false # Abort execution
        end

        true
      end

      def can_view_card?(card)
        # Use Decko's permission system to check read access
        Card::Auth.as(current_account.name) do
          card.ok?(:read)
        end
      end

      def can_modify_card?(card)
        # Use Decko's permission system to check update access
        # Admin and GM can update, but user role has restrictions
        Card::Auth.as(current_account.name) do
          card.ok?(:update)
        end
      end

      def render_forbidden_gm_content
        render_forbidden(
          "Role '#{current_role}' cannot access GM content",
          { card: @card.name, required_role: "gm" }
        )
      end

      def build_search_query
        query = {}

        # Handle name filters - prefix takes precedence if both provided
        if params[:prefix]
          query[:name] = ["starts_with", params[:prefix]]
        elsif params[:q]
          query[:name] = ["match", params[:q]]
        end

        query[:type] = params[:type] if params[:type]

        if params[:not_name]
          # Simple glob pattern support
          pattern = params[:not_name].gsub("*", "%")
          query[:not] = { name: ["like", pattern] }
        end

        # Handle date range filters - combine if both provided
        if params[:updated_since] && params[:updated_before]
          # Both range bounds - use BETWEEN
          query[:updated_at] = [
            "BETWEEN",
            Time.parse(params[:updated_since]),
            Time.parse(params[:updated_before])
          ]
        elsif params[:updated_since]
          query[:updated_at] = [">=", Time.parse(params[:updated_since])]
        elsif params[:updated_before]
          query[:updated_at] = ["<=", Time.parse(params[:updated_before])]
        end

        query
      end

      def execute_search(query, limit, offset)
        # Execute search with proper permission context
        Card::Auth.as(current_account.name) do
          cards = Card.search(query.merge(limit: limit, offset: offset))

          # Filter by Decko permissions - only return cards user can read
          cards.select { |c| c.ok?(:read) }
        end
      end

      def count_search_results(query)
        # Count with proper permission context - only count cards user can read
        Card::Auth.as(current_account.name) do
          cards = Card.search(query)
          cards.select { |c| c.ok?(:read) }.count
        end
      end

      def find_type_by_name(name)
        type_card = Card.fetch(name, skip_modules: true)
        return type_card if type_card&.type_id == Card::CardtypeID

        Card.search(type: "Cardtype", name: ["match", name]).first
      end

      def prepare_content(content, markdown_content)
        return content if content

        if markdown_content
          convert_markdown_to_html(markdown_content)
        end
      end

      def convert_markdown_to_html(markdown)
        # Phase 2: Use proper kramdown-based converter
        McpApi::MarkdownConverter.markdown_to_html(markdown)
      end

      def apply_patch(card, patch_params)
        mode = patch_params[:mode]

        case mode
        when "replace_between"
          apply_replace_between(card, patch_params)
        else
          raise ArgumentError, "Unknown patch mode: #{mode}"
        end
      end

      def apply_replace_between(card, patch_params)
        start_marker = patch_params[:start_marker]
        end_marker = patch_params[:end_marker]
        replacement = patch_params[:replacement_html]
        # Default end_inclusive to false per spec
        end_inclusive = patch_params.key?(:end_inclusive) ? patch_params[:end_inclusive] : false

        content = card.content
        start_idx = content.index(start_marker)

        unless start_idx
          raise ArgumentError, "Start marker not found: #{start_marker}"
        end

        end_idx = content.index(end_marker, start_idx + start_marker.length)

        unless end_idx
          raise ArgumentError, "End marker not found: #{end_marker}"
        end

        # Adjust end index based on end_inclusive flag
        end_idx += end_marker.length if end_inclusive

        new_content = content[0...start_idx] + replacement + content[end_idx..-1]
        card.content = new_content
        card.save!
      end

      def process_batch_ops(ops)
        ops.map do |op|
          process_single_op(op)
        rescue StandardError => e
          {
            status: "error",
            name: op["name"],
            message: e.message
          }
        end
      end

      def process_single_op(op)
        action = op["action"]
        name = op["name"]

        case action
        when "create"
          process_create_op(op)
        when "update"
          process_update_op(op)
        else
          { status: "error", name: name, message: "Unknown action: #{action}" }
        end
      end

      def process_create_op(op)
        name = op["name"]
        type_name = op["type"]
        content = prepare_content(op["content"], op["markdown_content"])
        fetch_or_init = op["fetch_or_initialize"]

        type_card = find_type_by_name(type_name)
        return { status: "error", name: name, message: "Type not found: #{type_name}" } unless type_card

        Card::Auth.as(current_account.name) do
          if fetch_or_init
            card = Card.fetch(name, new: {})
            card.type_id = type_card.id
            card.content = content if content
            card.save!
          else
            card = Card.create!(name: name, type_id: type_card.id, content: content)
          end

          # Create children if specified
          create_children(card, op["children"]) if op["children"]

          { status: "ok", name: card.name, id: card.id }
        end
      rescue StandardError => e
        { status: "error", name: name, message: e.message }
      end

      def process_update_op(op)
        name = op["name"]
        card = Card.fetch(name)

        return { status: "error", name: name, message: "Card not found" } unless card

        # Check permission before attempting update
        can_update = Card::Auth.as(current_account.name) { card.ok?(:update) }
        return { status: "error", name: name, message: "Permission denied" } unless can_update

        Card::Auth.as(current_account.name) do
          if op["patch"]
            apply_patch(card, op["patch"])
          else
            content = prepare_content(op["content"], op["markdown_content"])
            card.content = content if content
            card.save!
          end

          { status: "ok", name: card.name, id: card.id }
        end
      rescue StandardError => e
        { status: "error", name: name, message: e.message }
      end

      def create_children(parent_card, children_specs)
        children_specs.each do |child_spec|
          child_name = child_spec["name"]

          # Prepend parent name if child name starts with *
          if child_name.start_with?("*")
            child_name = "#{parent_card.name}+#{child_name}"
          end

          type_name = child_spec["type"]
          type_card = find_type_by_name(type_name)
          next unless type_card

          content = prepare_content(child_spec["content"], child_spec["markdown_content"])

          # Create child with service account permission context
          Card::Auth.as(current_account.name) do
            Card.create!(
              name: child_name,
              type_id: type_card.id,
              content: content
            )
          end
        end
      end

      def card_summary_json(card)
        {
          name: card.name,
          id: card.id,
          type: card.type_name,
          updated_at: card.updated_at.iso8601
        }
      end

      def card_full_json(card)
        {
          name: card.name,
          id: card.id,
          type: card.type_name,
          codename: card.codename,
          content: card.content,
          updated_at: card.updated_at.iso8601,
          created_at: card.created_at.iso8601
        }
      end
    end
  end
end
