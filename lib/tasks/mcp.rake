# frozen_string_literal: true

require "securerandom"

namespace :mcp do
  desc "Idempotently create MCP service accounts (mcp-user, mcp-gm, mcp-admin) with role-appropriate permissions"
  task setup_roles: :environment do
    accounts = [
      {
        name: ENV.fetch("MCP_USER_NAME", "mcp-user"),
        email: ENV["MCP_USER_EMAIL"],
        password: ENV["MCP_USER_PASSWORD"],
        role: :user
      },
      {
        name: ENV.fetch("MCP_GM_NAME", "mcp-gm"),
        email: ENV["MCP_GM_EMAIL"],
        password: ENV["MCP_GM_PASSWORD"],
        role: :gm
      },
      {
        name: ENV.fetch("MCP_ADMIN_NAME", "mcp-admin"),
        email: ENV["MCP_ADMIN_EMAIL"],
        password: ENV["MCP_ADMIN_PASSWORD"],
        role: :admin
      }
    ]

    missing_creds = accounts.select { |a| a[:email].to_s.empty? || a[:password].to_s.empty? }
    if missing_creds.any?
      puts "⚠️  Skipping creation for accounts missing email/password:"
      missing_creds.each do |acct|
        puts "  - #{acct[:name]} (role: #{acct[:role]})"
      end
      puts "Set MCP_*_EMAIL and MCP_*_PASSWORD env vars to create missing accounts."
    end

    Card::Auth.as_bot do
      user_type_id = Card.fetch_id(:user)
      created = []
      skipped = []

      accounts.each do |acct|
        existing = Card[acct[:name]]
        if existing
          skipped << { name: acct[:name], id: existing.id, status: :exists }
          next
        end

        if acct[:email].to_s.empty? || acct[:password].to_s.empty?
          skipped << { name: acct[:name], id: nil, status: :missing_credentials }
          next
        end

        password = acct[:password]
        # Decko stores account info on subcards; create user with account/email/password/status.
        card = Card.create!(
          name: acct[:name],
          type_id: user_type_id,
          subcards: {
            "+*account+*email" => acct[:email],
            "+*account+*password" => password,
            "+*account+*status" => "active"
          }
        )
        created << { name: acct[:name], id: card.id }
      rescue StandardError => e
        skipped << { name: acct[:name], id: nil, status: :error, error: e.message }
      end

      puts "✅ Created: #{created.map { |c| "#{c[:name]}(##{c[:id]})" }.join(', ')}" unless created.empty?
      puts "ℹ️  Skipped: #{skipped.map { |s| "#{s[:name]}(#{s[:status]})" }.join(', ')}" unless skipped.empty?
    end
  end
end
