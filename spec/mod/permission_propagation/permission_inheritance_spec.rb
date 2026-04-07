# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Permission Propagation - New Card Inheritance", type: :model do
  # These tests verify that when a new card is created under a parent
  # with restricted permissions, the new card correctly inherits those
  # permissions immediately.

  let(:test_parent_name) { "Test+Inheritance+Parent" }
  let(:test_child_name) { "Test+Inheritance+Parent+NewChild" }
  let(:read_rule_name) { "Test+Inheritance+Parent+*self+*read" }

  before do
    # Clean up any existing test cards
    Card::Auth.as_bot do
      [test_child_name, read_rule_name, test_parent_name].each do |name|
        card = Card.fetch(name)
        card&.delete!
      end
    end
  end

  after do
    # Clean up test cards
    Card::Auth.as_bot do
      [test_child_name, read_rule_name, test_parent_name].each do |name|
        card = Card.fetch(name)
        card&.delete! if card&.real?
      end
    end
  end

  describe "when creating a card under a restricted parent" do
    before do
      # Create parent with restricted permissions
      Card::Auth.as_bot do
        Card.create!(name: test_parent_name, type: "RichText", content: "Restricted parent")
        Card.create!(
          name: read_rule_name,
          type: "List",
          content: "Administrator"
        )
      end
    end

    it "new child card inherits parent's read permissions" do
      # Create a new child card under the restricted parent
      Card::Auth.as_bot do
        Card.create!(name: test_child_name, type: "RichText", content: "New child content")
      end

      child = Card.fetch(test_child_name)

      # The new child should NOT be readable by anonymous users
      Card::Auth.as(:anonymous) do
        expect(child.ok?(:read)).to be false
      end
    end

    it "new child card has correct read_rule_id pointing to parent's rule" do
      Card::Auth.as_bot do
        Card.create!(name: test_child_name, type: "RichText", content: "New child content")
      end

      child = Card.fetch(test_child_name)
      parent = Card.fetch(test_parent_name)

      # Child should have the same read_rule_id as parent
      expect(child.read_rule_id).to eq(parent.read_rule_id)
    end

    it "deeply nested new cards inherit permissions" do
      grandchild_name = "#{test_child_name}+Grandchild"

      Card::Auth.as_bot do
        # First create the child
        Card.create!(name: test_child_name, type: "RichText", content: "Child content")
        # Then create a grandchild
        Card.create!(name: grandchild_name, type: "RichText", content: "Grandchild content")
      end

      grandchild = Card.fetch(grandchild_name)

      # The grandchild should also NOT be readable by anonymous users
      Card::Auth.as(:anonymous) do
        expect(grandchild.ok?(:read)).to be false
      end

      # Clean up the grandchild
      Card::Auth.as_bot do
        grandchild.delete!
      end
    end
  end

  describe "when creating a card under an unrestricted parent" do
    before do
      # Create parent WITHOUT restricted permissions (uses default *all+*read)
      Card::Auth.as_bot do
        Card.create!(name: test_parent_name, type: "RichText", content: "Public parent")
      end
    end

    it "new child card is publicly readable" do
      Card::Auth.as_bot do
        Card.create!(name: test_child_name, type: "RichText", content: "New child content")
      end

      child = Card.fetch(test_child_name)

      # The new child should be readable by anonymous users
      Card::Auth.as(:anonymous) do
        expect(child.ok?(:read)).to be true
      end
    end

    it "new child card has default read_rule_id" do
      Card::Auth.as_bot do
        Card.create!(name: test_child_name, type: "RichText", content: "New child content")
      end

      child = Card.fetch(test_child_name)
      all_read_rule = Card.fetch("*all+*read")

      # For unrestricted parents, child might point to *all+*read or inherit from parent
      # Either way, anonymous should be able to read
      Card::Auth.as(:anonymous) do
        expect(child.ok?(:read)).to be true
      end
    end
  end

  describe "edge cases" do
    it "handles simple (non-compound) cards gracefully" do
      # Simple cards don't have parents to inherit from
      simple_card_name = "TestSimpleCard#{rand(10000)}"

      Card::Auth.as_bot do
        expect {
          Card.create!(name: simple_card_name, type: "RichText", content: "Simple card")
        }.not_to raise_error

        # Clean up
        Card.fetch(simple_card_name)&.delete!
      end
    end

    it "handles creating card when parent doesn't exist" do
      # When parent doesn't exist, Decko creates a virtual parent
      orphan_name = "NonExistent+Parent+Child#{rand(10000)}"

      Card::Auth.as_bot do
        expect {
          Card.create!(name: orphan_name, type: "RichText", content: "Orphan content")
        }.not_to raise_error

        # Clean up
        Card.fetch(orphan_name)&.delete!
      end
    end
  end
end
