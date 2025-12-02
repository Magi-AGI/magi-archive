# frozen_string_literal: true

require "kramdown"
require "reverse_markdown"

module McpApi
  class MarkdownConverter
    class << self
      # Convert Markdown to Decko-safe HTML
      # Preserves wiki links [[Card+Name|Label]]
      def markdown_to_html(markdown)
        return "" if markdown.nil? || markdown.empty?

        # Step 1: Protect wiki links by temporarily replacing them
        wiki_links = {}
        protected_markdown = markdown.gsub(/\[\[(.*?)\]\]/) do |match|
          key = "__WIKILINK_#{wiki_links.size}__"
          wiki_links[key] = match
          key
        end

        # Step 2: Convert Markdown to HTML using kramdown
        doc = Kramdown::Document.new(protected_markdown, kramdown_options)
        html = doc.to_html

        # Step 3: Restore wiki links
        wiki_links.each do |key, link|
          html.gsub!(key, link)
        end

        # Step 4: Basic sanitization (remove script/style tags)
        sanitize_html(html)
      end

      # Convert HTML to Markdown
      # Preserves wiki links [[Card+Name|Label]]
      def html_to_markdown(html)
        return "" if html.nil? || html.empty?

        # Step 1: Protect wiki links
        wiki_links = {}
        protected_html = html.gsub(/\[\[(.*?)\]\]/) do |match|
          key = "__WIKILINK_#{wiki_links.size}__"
          wiki_links[key] = match
          key
        end

        # Step 2: Convert HTML to Markdown
        markdown = ReverseMarkdown.convert(
          protected_html,
          reverse_markdown_options
        )

        # Step 3: Restore wiki links
        wiki_links.each do |key, link|
          markdown.gsub!(key, link)
        end

        markdown
      end

      private

      def kramdown_options
        {
          input: "GFM", # GitHub Flavored Markdown
          hard_wrap: false,
          auto_ids: false, # Don't generate IDs for headers
          entity_output: :as_char,
          syntax_highlighter: nil # Disable syntax highlighting for simplicity
        }
      end

      def reverse_markdown_options
        {
          unknown_tags: :pass_through,
          github_flavored: true
        }
      end

      def sanitize_html(html)
        # Remove script and style tags (basic XSS prevention)
        sanitized = html.gsub(/<script\b[^>]*>.*?<\/script>/im, "")
        sanitized.gsub(/<style\b[^>]*>.*?<\/style>/im, "")
      end
    end
  end
end
