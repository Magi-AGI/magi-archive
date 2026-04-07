# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Permission Propagation - Read Rule Changes", type: :model do
  # These tests verify that when a +*read rule is created or modified,
  # the permission changes propagate to all descendant cards.

  let(:test_parent_name) { "Test+Permission+Parent" }
  let(:test_child_name) { "Test+Permission+Parent+Child" }
  let(:test_grandchild_name) { "Test+Permission+Parent+Child+Grandchild" }
  let(:read_rule_name) { "Test+Permission+Parent+*self+*read" }

  before do
    # Clean up any existing test cards
    Card::Auth.as_bot do
      [test_grandchild_name, test_child_name, test_parent_name, read_rule_name].each do |name|
        card = Card.fetch(name)
        card&.delete!
      end
    end
  end

  after do
    # Clean up test cards
    Card::Auth.as_bot do
      [read_rule_name, test_grandchild_name, test_child_name, test_parent_name].each do |name|
        card = Card.fetch(name)
        card&.delete! if card&.real?
      end
    end
  end

  describe "when creating a +*self+*read rule" do
    before do
      # Create parent and child cards first (without restrictions)
      Card::Auth.as_bot do
        Card.create!(name: test_parent_name, type: "RichText", content: "Parent content")
        Card.create!(name: test_child_name, type: "RichText", content: "Child content")
        Card.create!(name: test_grandchild_name, type: "RichText", content: "Grandchild content")
      end
    end

    it "updates the parent card's read_rule_id" do
      parent = Card.fetch(test_parent_name)
      original_rule_id = parent.read_rule_id

      # Create the read rule
      Card::Auth.as_bot do
        Card.create!(
          name: read_rule_name,
          type: "List",
          content: "Administrator"
        )
      end

      parent.reload
      expect(parent.read_rule_id).not_to eq(original_rule_id)

      rule = Card.fetch(parent.read_rule_id)
      expect(rule.name).to eq(read_rule_name)
    end

    it "propagates permissions to child cards" do
      child = Card.fetch(test_child_name)

      # Before: child should be readable by anyone (inherits from *all+*read)
      Card::Auth.as(:anonymous) do
        expect(child.ok?(:read)).to be true
      end

      # Create the read rule on parent
      Card::Auth.as_bot do
        Card.create!(
          name: read_rule_name,
          type: "List",
          content: "Administrator"
        )
      end

      child.reload

      # After: child should NOT be readable by anonymous (inherits from parent's restricted rule)
      Card::Auth.as(:anonymous) do
        expect(child.ok?(:read)).to be false
      end
    end

    it "propagates permissions to grandchild cards" do
      grandchild = Card.fetch(test_grandchild_name)

      # Before: grandchild should be readable by anyone
      Card::Auth.as(:anonymous) do
        expect(grandchild.ok?(:read)).to be true
      end

      # Create the read rule on parent
      Card::Auth.as_bot do
        Card.create!(
          name: read_rule_name,
          type: "List",
          content: "Administrator"
        )
      end

      grandchild.reload

      # After: grandchild should NOT be readable by anonymous
      Card::Auth.as(:anonymous) do
        expect(grandchild.ok?(:read)).to be false
      end
    end
  end

  describe "when updating a +*self+*read rule" do
    let(:gm_role) { "Game Master" }

    before do
      # Create parent, child, and an initial restrictive rule
      Card::Auth.as_bot do
        Card.create!(name: test_parent_name, type: "RichText", content: "Parent content")
        Card.create!(name: test_child_name, type: "RichText", content: "Child content")
        Card.create!(
          name: read_rule_name,
          type: "List",
          content: "Administrator"
        )
      end
    end

    it "updates descendant permissions when rule content changes" do
      child = Card.fetch(test_child_name)

      # Initial state: only Administrator can read
      Card::Auth.as(:anonymous) do
        expect(child.ok?(:read)).to be false
      end

      # Update the rule to include Game Master role
      Card::Auth.as_bot do
        rule = Card.fetch(read_rule_name)
        rule.content = "Administrator\n#{gm_role}"
        rule.save!
      end

      child.reload

      # Rule should now include Game Master
      rule = Card.fetch(child.read_rule_id)
      expect(rule.content).to include(gm_role)
    end
  end

  describe "edge cases" do
    it "handles cards without children gracefully" do
      Card::Auth.as_bot do
        # Create a parent with no children
        Card.create!(name: test_parent_name, type: "RichText", content: "Parent content")

        # Create read rule - should not raise errors
        expect {
          Card.create!(
            name: read_rule_name,
            type: "List",
            content: "Administrator"
          )
        }.not_to raise_error
      end
    end

    it "skips rule cards themselves during propagation" do
      Card::Auth.as_bot do
        Card.create!(name: test_parent_name, type: "RichText", content: "Parent content")
        Card.create!(
          name: read_rule_name,
          type: "List",
          content: "Administrator"
        )
      end

      # The rule card should exist and not cause infinite loops
      rule_card = Card.fetch(read_rule_name)
      expect(rule_card).to be_present
      expect(rule_card.type_name).to eq("List")
    end
  end
end
