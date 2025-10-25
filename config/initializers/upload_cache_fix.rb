# Fix for Decko file upload bug - forces select_action callbacks to run
# This ensures the CarrierWave uploader is rehydrated from the cached upload
# before validation fires.
#
# Problem: Stage 2 of upload flow skipped select_action callbacks, leaving
# attachment.file empty and causing "File is missing" validation error.
#
# Solution: Override assign_attachment_on_create to use with_selected_action_id
# wrapper, which forces callbacks and loads the cached file.

Rails.application.config.after_initialize do
  module UploadCacheFix
    def assign_attachment_on_create
      return unless (action = Card::Action.fetch(@action_id_of_cached_upload))

      Rails.logger.info "=== UploadCacheFix: Fetched action #{action.id} for cached upload"

      # Use with_selected_action_id to force select_action callbacks
      upload_cache_card.with_selected_action_id(action.id) do
        Rails.logger.info "=== UploadCacheFix: Running select_file_revision within callback context"
        upload_cache_card.select_file_revision
      end

      # Verify the attachment was loaded
      if upload_cache_card.attachment.file.present?
        Rails.logger.info "=== UploadCacheFix: Successfully loaded cached file"
        assign_attachment upload_cache_card.attachment.file, action.comment
      else
        Rails.logger.warn "=== UploadCacheFix: WARNING - Cached file still not loaded after callback! Action: #{action.id}, Cache card: #{upload_cache_card.id}"
        # Try to proceed anyway - assign_attachment will handle the error
        assign_attachment upload_cache_card.attachment.file, action.comment
      end
    end
  end

  if defined?(Card) && defined?(Card::Set) && defined?(Card::Set::Type) && defined?(Card::Set::Type::File)
    Card::Set::Type::File.send(:prepend, UploadCacheFix)
    Rails.logger.info "=== Applied UploadCacheFix patch to Card::Set::Type::File"
  end
end
