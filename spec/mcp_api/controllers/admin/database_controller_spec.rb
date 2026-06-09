# frozen_string_literal: true

require "rails_helper"

RSpec.describe Api::Mcp::Admin::DatabaseController, type: :request do
  include McpApiTestHelper

  let(:valid_api_key) { ENV["MCP_API_KEY"] || "test-api-key-for-specs" }

  def token_for_role(role)
    post "/api/mcp/auth", params: { api_key: valid_api_key, role: role }
    JSON.parse(response.body)["token"]
  end

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("MCP_API_KEY").and_return(valid_api_key)
    allow(ENV).to receive(:fetch).and_call_original
  end

  let(:admin_token) { token_for_role("admin") }
  let(:user_token) { token_for_role("user") }
  let(:backup_dir) { Rails.root.join("tmp", "backups") }

  before do
    FileUtils.mkdir_p(backup_dir)
  end

  after do
    # Clean up test backup files
    FileUtils.rm_rf(backup_dir) if Dir.exist?(backup_dir)
  end

  describe "GET /api/mcp/admin/database/backup" do
    context "with admin role" do
      it "creates and returns a gzip-compressed database backup (T8)" do
        get "/api/mcp/admin/database/backup",
            headers: { "Authorization" => "Bearer #{admin_token}" }

        expect(response).to have_http_status(:success)
        # T8: backups are now gzip-compressed
        expect(response.headers["Content-Type"]).to eq("application/gzip")
        expect(response.headers["Content-Disposition"]).to include("attachment")
        expect(response.body).not_to be_empty
        # gzip magic bytes
        expect(response.body.bytes.first(2)).to eq([0x1f, 0x8b])
      end

      it "exposes an X-Backup-SHA256 checksum matching the body (T8)" do
        get "/api/mcp/admin/database/backup",
            headers: { "Authorization" => "Bearer #{admin_token}" }

        expect(response).to have_http_status(:success)
        # The client (verify_and_save) checks this header against the bytes it
        # received so "success" means the dump actually landed intact.
        expect(response.headers["X-Backup-SHA256"]).to eq(Digest::SHA256.hexdigest(response.body))
      end

      it "creates backup file with a .sql.gz timestamped name (T8)" do
        get "/api/mcp/admin/database/backup",
            headers: { "Authorization" => "Bearer #{admin_token}" }

        expect(response).to have_http_status(:success)
        filename = response.headers["Content-Disposition"].match(/filename="(.+)"/)[1]
        expect(filename).to match(/\Amagi_archive_backup_\d{8}_\d{6}\.sql\.gz\z/)
      end
    end

    context "without admin role" do
      it "denies access to user role" do
        get "/api/mcp/admin/database/backup",
            headers: { "Authorization" => "Bearer #{user_token}" }

        # User is authenticated but lacks admin role, so 403 Forbidden is correct
        expect(response).to have_http_status(:forbidden)
      end

      it "denies access without token" do
        get "/api/mcp/admin/database/backup"

        # No token = not authenticated, so 401 Unauthorized is correct
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  describe "GET /api/mcp/admin/database/backup/list" do
    before do
      # Create test backup files
      3.times do |i|
        File.write(backup_dir.join("magi_archive_backup_2025120#{i}_120000.sql"), "test backup #{i}")
        sleep 0.01 # Ensure different mtimes
      end
    end

    context "with admin role" do
      it "lists all backup files" do
        get "/api/mcp/admin/database/backup/list",
            headers: { "Authorization" => "Bearer #{admin_token}" }

        expect(response).to have_http_status(:success)
        json = JSON.parse(response.body)

        expect(json["backups"]).to be_an(Array)
        expect(json["total"]).to eq(3)
        expect(json["backup_dir"]).to eq(backup_dir.to_s)
      end

      it "includes file metadata" do
        get "/api/mcp/admin/database/backup/list",
            headers: { "Authorization" => "Bearer #{admin_token}" }

        json = JSON.parse(response.body)
        backup = json["backups"].first

        expect(backup).to have_key("filename")
        expect(backup).to have_key("size")
        expect(backup).to have_key("size_human")
        expect(backup).to have_key("created_at")
        expect(backup).to have_key("modified_at")
        expect(backup).to have_key("age")
      end

      it "sorts backups by modification time (newest first)" do
        get "/api/mcp/admin/database/backup/list",
            headers: { "Authorization" => "Bearer #{admin_token}" }

        json = JSON.parse(response.body)
        filenames = json["backups"].map { |b| b["filename"] }

        # Most recent should be first
        expect(filenames).to eq(filenames.sort.reverse)
      end

      it "includes .sql.gz backups in the listing (T8)" do
        File.binwrite(backup_dir.join("magi_archive_backup_20260101_000000.sql.gz"), "\x1f\x8b\x08gz")
        get "/api/mcp/admin/database/backup/list",
            headers: { "Authorization" => "Bearer #{admin_token}" }
        json = JSON.parse(response.body)
        names = json["backups"].map { |b| b["filename"] }
        expect(names).to include("magi_archive_backup_20260101_000000.sql.gz")
      end
    end

    context "when no backups exist" do
      before do
        FileUtils.rm_rf(backup_dir)
      end

      it "returns empty list" do
        get "/api/mcp/admin/database/backup/list",
            headers: { "Authorization" => "Bearer #{admin_token}" }

        json = JSON.parse(response.body)
        expect(json["backups"]).to eq([])
        expect(json["total"]).to eq(0)
      end
    end
  end

  describe "GET /api/mcp/admin/database/backup/download/:filename" do
    let(:test_filename) { "magi_archive_backup_20251203_120000.sql" }

    before do
      File.write(backup_dir.join(test_filename), "test backup content")
    end

    context "with valid filename" do
      it "downloads the specified backup file" do
        get "/api/mcp/admin/database/backup/download/#{test_filename}",
            headers: { "Authorization" => "Bearer #{admin_token}" }

        expect(response).to have_http_status(:success)
        expect(response.body).to eq("test backup content")
        expect(response.headers["Content-Disposition"]).to include(test_filename)
      end

      it "serves .sql.gz with gzip content-type + checksum header (T8)" do
        gz = "magi_archive_backup_20251203_120000.sql.gz"
        File.binwrite(backup_dir.join(gz), "\x1f\x8b\x08binary\x00gzip")
        get "/api/mcp/admin/database/backup/download/#{gz}",
            headers: { "Authorization" => "Bearer #{admin_token}" }

        expect(response).to have_http_status(:success)
        expect(response.headers["Content-Type"]).to eq("application/gzip")
        expect(response.headers["X-Backup-SHA256"]).to eq(Digest::SHA256.hexdigest(response.body))
      end
    end

    context "with invalid filename" do
      it "rejects path traversal attempts" do
        get "/api/mcp/admin/database/backup/download/../../../etc/passwd",
            headers: { "Authorization" => "Bearer #{admin_token}" }

        # Path traversal is blocked - any non-success response is acceptable
        # Could be 400, 403, 404, or even caught by web server returning HTML
        expect(response.status).to be >= 400
      end

      it "rejects filenames with special characters", skip: "URL with semicolon/space is invalid URI" do
        get "/api/mcp/admin/database/backup/download/backup;rm -rf.sql",
            headers: { "Authorization" => "Bearer #{admin_token}" }

        # 400 or 403 are both valid rejection responses for invalid filenames
        expect(response.status).to be_in([400, 403, 404])
      end
    end

    context "when file doesn't exist" do
      it "returns not found error" do
        get "/api/mcp/admin/database/backup/download/nonexistent.sql",
            headers: { "Authorization" => "Bearer #{admin_token}" }

        expect(response).to have_http_status(:not_found)
        json = JSON.parse(response.body)
        expect(json["error"]).to eq("not_found")
      end
    end
  end

  describe "DELETE /api/mcp/admin/database/backup/:filename" do
    let(:test_filename) { "magi_archive_backup_20251203_120000.sql" }

    before do
      File.write(backup_dir.join(test_filename), "test backup content")
    end

    context "with valid filename" do
      it "deletes the backup file" do
        expect(File.exist?(backup_dir.join(test_filename))).to be true

        delete "/api/mcp/admin/database/backup/#{test_filename}",
               headers: { "Authorization" => "Bearer #{admin_token}" }

        expect(response).to have_http_status(:success)
        json = JSON.parse(response.body)
        expect(json["message"]).to include("deleted successfully")
        expect(json["filename"]).to eq(test_filename)

        expect(File.exist?(backup_dir.join(test_filename))).to be false
      end
    end

    context "with invalid filename" do
      it "rejects path traversal attempts" do
        delete "/api/mcp/admin/database/backup/../../../important_file",
               headers: { "Authorization" => "Bearer #{admin_token}" }

        # 400 or 403 are both valid rejection responses for invalid filenames
        expect(response.status).to be_in([400, 403, 404])
      end
    end
  end

  # Helper method to generate test tokens
  def generate_jwt_token(role:)
    payload = {
      role: role,
      iat: Time.now.to_i,
      exp: (Time.now + 1.hour).to_i
    }
    # Use MessageVerifier for tests
    verifier = ActiveSupport::MessageVerifier.new(Rails.application.secret_key_base)
    verifier.generate(payload)
  end
end
