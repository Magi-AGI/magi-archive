# frozen_string_literal: true

require "rails_helper"
require_relative "../../../mod/mcp_api/lib/mcp/roles"

RSpec.describe Mcp::Roles do
  before do
    # Clear cached roles before each test
    described_class.clear_cache!
  end

  describe ".valid?" do
    it "returns true for legacy MCP roles" do
      expect(described_class.valid?("admin")).to be true
      expect(described_class.valid?("gm")).to be true
      expect(described_class.valid?("user")).to be true
    end

    it "returns true for Decko roles that exist" do
      # These roles exist in the wiki
      expect(described_class.valid?("Administrator")).to be true
      expect(described_class.valid?("Game Master")).to be true
    end

    it "is case-insensitive for legacy roles" do
      expect(described_class.valid?("ADMIN")).to be true
      expect(described_class.valid?("Admin")).to be true
      expect(described_class.valid?("GM")).to be true
      expect(described_class.valid?("USER")).to be true
    end
  end

  describe ".all" do
    it "returns an array of role names" do
      roles = described_class.all
      expect(roles).to be_an(Array)
      expect(roles).not_to be_empty
    end

    it "includes standard Decko roles" do
      roles = described_class.all
      expect(roles).to include("Administrator")
      expect(roles).to include("Game Master")
    end

    it "caches the result" do
      first_call = described_class.all
      second_call = described_class.all
      expect(first_call).to equal(second_call) # Same object reference
    end
  end

  describe ".clear_cache!" do
    it "clears the cached roles" do
      first_call = described_class.all
      described_class.clear_cache!
      second_call = described_class.all
      expect(first_call).not_to equal(second_call) # Different object reference
    end
  end

  describe ".normalize" do
    it "maps Administrator to admin" do
      expect(described_class.normalize("Administrator")).to eq("admin")
      expect(described_class.normalize("administrator")).to eq("admin")
    end

    it "maps Game Master to gm" do
      expect(described_class.normalize("Game Master")).to eq("gm")
      expect(described_class.normalize("game master")).to eq("gm")
      expect(described_class.normalize("GM")).to eq("gm")
    end

    it "returns lowercase for unknown roles" do
      expect(described_class.normalize("Magi Team")).to eq("magi team")
      expect(described_class.normalize("EARTHwise Team")).to eq("earthwise team")
    end

    it "returns user for nil" do
      expect(described_class.normalize(nil)).to eq("user")
    end
  end

  describe ".level" do
    it "returns 3 for admin roles" do
      expect(described_class.level("admin")).to eq(3)
      expect(described_class.level("Administrator")).to eq(3)
    end

    it "returns 2 for gm roles" do
      expect(described_class.level("gm")).to eq(2)
      expect(described_class.level("Game Master")).to eq(2)
    end

    it "returns 1 for user role" do
      expect(described_class.level("user")).to eq(1)
    end

    it "returns 2 for roles that can view GM content" do
      # Magi Team is in GM_CONTENT_ROLES
      expect(described_class.level("magi team")).to eq(2)
    end

    it "returns 1 for roles that cannot view GM content" do
      expect(described_class.level("EARTHwise Team")).to eq(1)
    end
  end

  describe ".highest_role" do
    it "returns admin when user has Administrator role" do
      roles = ["Administrator", "Game Master", "Anyone Signed In"]
      expect(described_class.highest_role(roles)).to eq("admin")
    end

    it "returns gm when highest role is Game Master" do
      roles = ["Game Master", "Anyone Signed In"]
      expect(described_class.highest_role(roles)).to eq("gm")
    end

    it "returns user for empty roles array" do
      expect(described_class.highest_role([])).to eq("user")
    end

    it "returns custom role when no admin/gm roles present" do
      roles = ["Magi Team", "Anyone Signed In"]
      expect(described_class.highest_role(roles)).to eq("magi team")
    end

    it "filters out system roles like Anyone" do
      roles = ["Anyone", "Anyone Signed In"]
      expect(described_class.highest_role(roles)).to eq("user")
    end
  end

  describe ".can_view_gm_content?" do
    it "returns true for admin" do
      expect(described_class.can_view_gm_content?("admin")).to be true
      expect(described_class.can_view_gm_content?("administrator")).to be true
    end

    it "returns true for gm" do
      expect(described_class.can_view_gm_content?("gm")).to be true
      expect(described_class.can_view_gm_content?("game master")).to be true
    end

    it "returns true for magi team" do
      expect(described_class.can_view_gm_content?("magi team")).to be true
    end

    it "returns false for user role" do
      expect(described_class.can_view_gm_content?("user")).to be false
    end

    it "returns false for earthwise team" do
      expect(described_class.can_view_gm_content?("earthwise team")).to be false
    end

    it "returns true for nil (defers to Decko permissions)" do
      expect(described_class.can_view_gm_content?(nil)).to be true
    end
  end

  describe ".can_assume_role?" do
    it "allows admin to assume any role" do
      user_roles = ["Administrator"]
      expect(described_class.can_assume_role?(user_roles, "admin")).to be true
      expect(described_class.can_assume_role?(user_roles, "gm")).to be true
      expect(described_class.can_assume_role?(user_roles, "user")).to be true
    end

    it "allows gm to assume gm or user roles" do
      user_roles = ["Game Master"]
      expect(described_class.can_assume_role?(user_roles, "admin")).to be false
      expect(described_class.can_assume_role?(user_roles, "gm")).to be true
      expect(described_class.can_assume_role?(user_roles, "user")).to be true
    end

    it "only allows user to assume user role" do
      user_roles = ["Anyone Signed In"]
      expect(described_class.can_assume_role?(user_roles, "admin")).to be false
      expect(described_class.can_assume_role?(user_roles, "gm")).to be false
      expect(described_class.can_assume_role?(user_roles, "user")).to be true
    end

    it "returns false for invalid roles" do
      user_roles = ["Administrator"]
      expect(described_class.can_assume_role?(user_roles, "superuser")).to be false
    end
  end

  describe ".legacy_mcp_role?" do
    it "returns true for admin, gm, user" do
      expect(described_class.legacy_mcp_role?("admin")).to be true
      expect(described_class.legacy_mcp_role?("gm")).to be true
      expect(described_class.legacy_mcp_role?("user")).to be true
    end

    it "returns false for Decko roles" do
      expect(described_class.legacy_mcp_role?("Administrator")).to be false
      expect(described_class.legacy_mcp_role?("Game Master")).to be false
      expect(described_class.legacy_mcp_role?("Magi Team")).to be false
    end
  end
end
