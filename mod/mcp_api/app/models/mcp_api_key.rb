# frozen_string_literal: true

# Phase 2: Database-backed API key management
# Provides secure, per-user API keys with role restrictions and audit trails
class McpApiKey < ApplicationRecord
  # Validations
  validates :key_hash, presence: true, uniqueness: true
  validates :key_prefix, presence: true, length: { is: 8 }
  validates :name, presence: true
  validates :allowed_roles, presence: true
  validates :rate_limit_per_hour, presence: true, numericality: { greater_than: 0 }
  validate :roles_must_be_valid

  # Scopes
  scope :active, -> { where(active: true).where("expires_at IS NULL OR expires_at > ?", Time.current) }
  scope :expired, -> { where("expires_at IS NOT NULL AND expires_at <= ?", Time.current) }
  scope :inactive, -> { where(active: false) }
  scope :recently_used, -> { where("last_used_at > ?", 24.hours.ago).order(last_used_at: :desc) }

  # Class methods

  # Generate a new API key with secure random token
  #
  # @param name [String] Human-readable name for the key
  # @param roles [Array<String>] Allowed roles (user, gm, admin)
  # @param rate_limit [Integer] Requests per hour limit
  # @param expires_in [ActiveSupport::Duration, nil] Expiration duration
  # @param created_by [String, nil] Admin who created the key
  # @param contact_email [String, nil] Key holder's email
  # @param description [String, nil] Additional notes
  # @return [Hash] { record: McpApiKey, api_key: String }
  def self.generate(name:, roles: ["user"], rate_limit: 1000, expires_in: nil,
                    created_by: nil, contact_email: nil, description: nil)
    # Generate cryptographically secure random key (64 hex chars = 32 bytes)
    api_key = SecureRandom.hex(32)
    key_hash = Digest::SHA256.hexdigest(api_key)
    key_prefix = api_key[0..7]

    # Create record
    record = create!(
      key_hash: key_hash,
      key_prefix: key_prefix,
      name: name,
      description: description,
      allowed_roles: Array(roles),
      rate_limit_per_hour: rate_limit,
      expires_at: expires_in ? Time.current + expires_in : nil,
      created_by: created_by,
      contact_email: contact_email,
      active: true
    )

    # Return both the record and the plaintext key (only time it's available!)
    { record: record, api_key: api_key }
  end

  # Find an API key by its plaintext value
  #
  # @param api_key [String] The plaintext API key
  # @return [McpApiKey, nil] The active, non-expired key record
  def self.find_by_key(api_key)
    return nil if api_key.blank?

    key_hash = Digest::SHA256.hexdigest(api_key)
    active.find_by(key_hash: key_hash)
  end

  # Verify an API key and return the record if valid
  #
  # @param api_key [String] The plaintext API key
  # @return [McpApiKey, nil] The key record if valid and active
  def self.authenticate(api_key)
    find_by_key(api_key)&.tap(&:touch_last_used!)
  end

  # Instance methods

  # Check if a role is allowed for this key
  #
  # @param role [String, Symbol] The role to check
  # @return [Boolean] True if role is allowed
  def role_allowed?(role)
    allowed_roles.include?(role.to_s)
  end

  # Update last_used_at timestamp
  def touch_last_used!
    update_column(:last_used_at, Time.current)
  end

  # Deactivate this key (soft delete)
  def deactivate!
    update!(active: false)
  end

  # Reactivate this key
  def activate!
    update!(active: true)
  end

  # Check if key is expired
  #
  # @return [Boolean] True if expired
  def expired?
    expires_at && expires_at <= Time.current
  end

  # Check if key is currently valid (active and not expired)
  #
  # @return [Boolean] True if valid
  def valid_for_use?
    active && !expired?
  end

  # Human-readable status
  #
  # @return [String] Status description
  def status
    return "expired" if expired?
    return "inactive" if !active
    return "active"
  end

  # Days until expiration
  #
  # @return [Integer, nil] Days remaining, or nil if no expiration
  def days_until_expiration
    return nil unless expires_at
    ((expires_at - Time.current) / 1.day).ceil
  end

  # Masked key for display (shows prefix only)
  #
  # @return [String] Masked key string
  def masked_key
    "#{key_prefix}#{'*' * 48}...#{key_prefix}"
  end

  # Usage statistics
  #
  # @return [Hash] Usage info
  def usage_info
    {
      last_used: last_used_at&.iso8601,
      days_since_last_use: last_used_at ? ((Time.current - last_used_at) / 1.day).floor : nil,
      status: status,
      days_until_expiration: days_until_expiration
    }
  end

  private

  # Validate that all roles are valid
  def roles_must_be_valid
    return if allowed_roles.blank?

    valid_roles = %w[user gm admin]
    invalid_roles = allowed_roles - valid_roles

    if invalid_roles.any?
      errors.add(:allowed_roles, "contains invalid roles: #{invalid_roles.join(', ')}. " \
                                  "Valid roles are: #{valid_roles.join(', ')}")
    end
  end
end
