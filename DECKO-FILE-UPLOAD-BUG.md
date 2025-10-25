# Decko File Upload Bug - Investigation & Attempted Solutions

**Date**: 2025-10-25
**Decko Version**: 0.19.1
**Environment**: Production on EC2 (Ubuntu 22.04), Cloudflare proxy (Flexible SSL)
**Status**: UNRESOLVED

---

## Problem Description

When attempting to upload PDF files through the Decko web interface, the upload fails with error:
```
Validation failed: File is missing
```

However, file uploads work perfectly when done programmatically via Rails console using `Card.create!()`.

---

## Technical Background

### Decko's Two-Stage Upload Process

Decko uses a two-stage file upload mechanism:

1. **Stage 1 (Preliminary Upload)**:
   - File is uploaded via POST to `/card/create` with `attachment_upload` parameter
   - Decko stores file in temporary location: `/home/<user>/<app-dir>/tmp/295/[action_id].pdf`
   - Creates a draft `Card::Action` record in database
   - Returns `action_id` to browser (e.g., 1183, 1185, 1187, etc.)

2. **Stage 2 (Final Submission)**:
   - User submits the form with `action_id_of_cached_upload` parameter
   - Decko should retrieve file from cache using `Card::Action.fetch(action_id)`
   - File should be assigned to the new card being created
   - File should be validated and saved permanently

**The bug occurs in Stage 2** - Decko fails to retrieve the cached file even though it exists on disk.

---

## Environment Configuration

### Server Setup
- **EC2 Instance**: <REDACTED_EC2_IP>
- **Application**: `/home/<user>/<app-dir>`
- **Database**: PostgreSQL RDS (<REDACTED_RDS_ENDPOINT>)
- **Web Server**: Nginx reverse proxy → Decko on port 3000
- **SSL**: Cloudflare "Flexible" mode (HTTPS → Cloudflare → HTTP → Server)

### File Storage Locations
- **Permanent files**: `/home/<user>/<app-dir>/files/[card_id]/[action_id].pdf`
- **Cached uploads**: `/home/<user>/<app-dir>/tmp/295/[action_id].pdf` (for `:new_file` card)
- **Carrierwave cache**: `/home/<user>/<app-dir>/tmp/cache/`

---

## Debugging Process

### 1. Initial Investigation

**Checked Nginx upload limits:**
```bash
# /etc/nginx/sites-available/magi-archive
client_max_body_size 100M;  # ✓ Adequate
```

**Verified file permissions:**
```bash
drwxrwxr-x ubuntu:ubuntu /home/<user>/<app-dir>/files/
```

**Examined logs:**
```
Started POST "/card/create" for [IP] at 2025-10-25 11:28:49 +0000
Processing by CardController#create as HTML
Parameters: {"card"=>{"type_id"=>"282", "file"=>#<ActionDispatch::Http::UploadedFile:0x00007cfafd989d90
  @tempfile=#<Tempfile:/tmp/RackMultipart20251025-73178-91c7i6.pdf>,
  @content_type="application/pdf",
  @original_filename="metta and graphs.pdf">},
  "attachment_upload"=>"card[file]"}
Completed 200 OK in 110ms  # ✓ Stage 1 succeeds

Started POST "/card/create?[params]" for [IP] at 2025-10-25 11:28:51 +0000
Processing by CardController#create as JS
Parameters: {"card"=>{"name"=>"Neoterics+Metta+metta-and-graphs+file",
  "type_id"=>"282",
  "file"=>"",  # ← Empty!
  "action_id_of_cached_upload"=>"1168"}, ...}
exception = Card::Error: Validation failed: File is missing  # ✗ Stage 2 fails
Completed 422 Unprocessable Entity
```

**Key finding:** The file parameter is empty in stage 2, but `action_id_of_cached_upload` is present.

---

### 2. Verified Files Exist

**Checked cached files:**
```bash
$ ls -lah /home/<user>/<app-dir>/tmp/295/
-rw-r--r-- 1 ubuntu ubuntu 187K Oct 25 11:28 1168.pdf  # ✓ Exists
-rw-r--r-- 1 ubuntu ubuntu 187K Oct 25 11:29 1170.pdf  # ✓ Exists
-rw-r--r-- 1 ubuntu ubuntu 187K Oct 25 11:39 1171.pdf  # ✓ Exists
```

**Checked database:**
```ruby
action = Card::Action.fetch(1168)
# => #<Card::Action id: 1168, card_id: 295, comment: "metta_and_graphs.pdf">
# ✓ Action record exists

action.card_changes.each { |c| puts "#{c.field}: #{c.value}" }
# name:
# type_id: 282
# db_content: ~295/1168.pdf  # ✓ File path stored correctly
```

**Conclusion:** Both the file and database record exist. The problem is retrieval.

---

### 3. Session/Cookie Issues (First Hypothesis)

**Issue:** Cloudflare's Flexible SSL mode terminates HTTPS at Cloudflare, then forwards HTTP to the server. Suspected Rails session cookies weren't working across the two-stage upload.

**Attempted Fix #1:**
```ruby
# config/initializers/session_store.rb
Rails.application.config.session_store :cookie_store,
  key: '_magi_archive_session',
  same_site: :lax,
  secure: false,  # ← Changed to false for HTTP from Cloudflare
  httponly: true,
  expire_after: 2.hours
```

**Result:** No change. Upload still failed.

---

### 4. Carrierwave Configuration (Second Hypothesis)

**Issue:** Suspected Carrierwave 3.x compatibility issues with Decko's cache mechanism.

**Attempted Fix #2:**
```ruby
# config/initializers/carrierwave.rb (REMOVED after testing)
CarrierWave.configure do |config|
  config.cache_storage = :file
  config.cache_dir = "#{Rails.root}/tmp/carrierwave_cache"
  config.remove_previously_stored_files_after_update = false
  config.enable_processing = true
end
```

**Result:** Created `/tmp/carrierwave_cache/` but didn't fix the issue. Configuration was removed as it interfered with Decko's native cache handling.

---

### 5. Set Module Loading (Third Hypothesis)

**Discovery:** The `:new_file` cache card wasn't loading its set modules during web requests, meaning attachment methods weren't available.

**Evidence:**
```ruby
new_file_card = Card.find(295)
new_file_card.respond_to?(:attachment)  # => false (without modules)
new_file_card.include_set_modules
new_file_card.respond_to?(:attachment)  # => true (with modules)
```

**Attempted Fix #3:**
```ruby
# config/initializers/decko_file_upload_fix.rb
Rails.application.config.after_initialize do
  module FixFileUpload
    def upload_cache_card
      cache_card_codename = "new_#{attachment_name}"
      @upload_cache_card ||= Card::Codename.card(cache_card_codename) { Card[:new_file] }

      # Force module loading
      @upload_cache_card.include_set_modules unless @upload_cache_card.set_mods_loaded?
      @upload_cache_card
    end
  end

  Card::Set::Type::File.send(:include, FixFileUpload)
end
```

**Result:** Modules now load (`=== upload_cache_card: *new file, modules loaded: true` in logs), but file validation still fails.

---

### 6. Root Cause Identified

**Manual testing revealed the core issue:**

```ruby
# Rails console test
action = Card::Action.fetch(1191)
upload_cache_card = Card.find(295)
upload_cache_card.include_set_modules

# Try to load the cached file
upload_cache_card.selected_action_id = 1191
upload_cache_card.select_file_revision
# => [:retrieve_versions_from_store!]

# Check if file loaded
upload_cache_card.attachment.present?
# => false  # ✗ FAIL - attachment not loaded!
```

**The `select_file_revision` method runs but doesn't populate the `attachment` object.**

Looking at the code in `set/abstract/attachment/00_upload_cache.rb`:

```ruby
event :assign_attachment_on_create, :initialize,
      after: :assign_action, on: :create, when: :save_preliminary_upload? do
  return unless (action = Card::Action.fetch(@action_id_of_cached_upload))

  upload_cache_card.selected_action_id = action.id
  upload_cache_card.select_file_revision  # ← This should load the file
  assign_attachment upload_cache_card.attachment.file, action.comment  # ← But .file is nil!
end
```

**The `upload_cache_card.attachment.file` is `nil` even after `select_file_revision`.**

---

## Why Console Upload Works

When uploading via console:

```ruby
Card::Auth.as_bot do
  Card.create!(
    name: "Test Upload",
    type_id: Card::FileID,
    file: File.open('/tmp/test.pdf')  # ← Direct file assignment
  )
end
```

This bypasses the two-stage cache mechanism entirely and assigns the file directly to the Carrierwave uploader.

---

## Logs Showing the Issue

**Stage 1 (Preliminary Upload) - SUCCEEDS:**
```
Started POST "/card/create"
Parameters: {"card"=>{"type_id"=>"282",
  "file"=>#<ActionDispatch::Http::UploadedFile @tempfile=#<Tempfile:/tmp/RackMultipart...>>}}
Completed 200 OK in 161ms
```

**Stage 2 (Final Submission) - FAILS:**
```
Started POST "/card/create?..."
Parameters: {"card"=>{"name"=>"Neoterics+Metta+metta-and-graphs+file",
  "type_id"=>"282",
  "file"=>"",  # ← Empty
  "action_id_of_cached_upload"=>"1189"}}
=== upload_cache_card: *new file, modules loaded: true  # ← Modules loaded
exception = Card::Error: Validation failed: File is missing  # ← Still fails
Completed 422 Unprocessable Entity
```

---

## Files Created During Investigation

### 1. `/home/<user>/<app-dir>/config/initializers/session_store.rb`
```ruby
# Session store configuration for Cloudflare compatibility
Rails.application.config.session_store :cookie_store,
  key: '_magi_archive_session',
  same_site: :lax,
  secure: false,  # HTTP from Cloudflare
  httponly: true,
  expire_after: 2.hours

Rails.application.config.action_dispatch.cookies_same_site_protection = :lax
```

### 2. `/home/<user>/<app-dir>/config/initializers/decko_file_upload_fix.rb`
```ruby
# Fix for file upload issue - ensures cache card has modules loaded
Rails.application.config.after_initialize do
  module FixFileUpload
    def upload_cache_card
      cache_card_codename = "new_#{attachment_name}"
      @upload_cache_card ||= Card::Codename.card(cache_card_codename) { Card[:new_file] }

      # CRITICAL FIX: Ensure modules are loaded before returning
      @upload_cache_card.include_set_modules unless @upload_cache_card.set_mods_loaded?
      Rails.logger.info "=== upload_cache_card: #{@upload_cache_card.name}, modules loaded: #{@upload_cache_card.set_mods_loaded?}"

      @upload_cache_card
    end
  end

  if defined?(Card) && defined?(Card::Set) && defined?(Card::Set::Type) && defined?(Card::Set::Type::File)
    Card::Set::Type::File.send(:include, FixFileUpload)
    Rails.logger.info "=== Applied FixFileUpload patch to Card::Set::Type::File"
  end
end
```

### 3. Created directories:
- `/home/<user>/<app-dir>/tmp/295/` (for cached uploads)
- `/home/<user>/<app-dir>/tmp/cache/` (Carrierwave cache)
- `/home/<user>/<app-dir>/tmp/uploads/` (attempted fix, not used)

---

## What Works

✓ File upload via Rails console (direct `Card.create!` with `file:` parameter)
✓ Stage 1 of web upload (preliminary upload to cache)
✓ Database action records are created correctly
✓ Files are stored in cache directory with correct permissions
✓ Set modules can be loaded manually on the cache card

---

## What Doesn't Work

✗ Stage 2 of web upload (final form submission with cached file retrieval)
✗ `select_file_revision` doesn't populate `attachment.file`
✗ Carrierwave uploader not initialized from cached upload
✗ Web interface file upload validation always fails

---

## Relevant Code Locations

### Decko Framework Files (in gems):
```
/home/ubuntu/.rbenv/versions/3.2.3/lib/ruby/gems/3.2.0/gems/card-mod-carrierwave-0.19.1/
├── set/abstract/attachment.rb
│   └── event :validate_file_exist (line 26) - Where "File is missing" error originates
├── set/abstract/attachment/00_upload_cache.rb
│   ├── event :assign_attachment_on_create (lines ~30-40)
│   ├── def save_preliminary_upload? - Checks if @action_id_of_cached_upload present
│   └── def upload_cache_card - Returns Card[:new_file]
└── lib/carrier_wave/file_card_uploader/path.rb
    └── def cache_dir - Returns "#{@model.files_base_dir 'tmp'}/cache"
```

### Key Database Records:
```ruby
Card.find(295)  # The :new_file cache card
Card::Action.where(card_id: 295, draft: true)  # Cached upload actions
```

---

## Hypothesis on Root Cause

The issue appears to be in Decko's `select_file_revision` method or how it interacts with Carrierwave's attachment loading mechanism. Specifically:

1. **`select_file_revision` runs** but returns only `[:retrieve_versions_from_store!]`
2. **The attachment uploader is not initialized** with the file from the selected action
3. **Carrierwave's presence validation fails** because `attachment.file.present?` returns `false`

This might be:
- A bug in how Decko retrieves files from draft actions
- An issue with Carrierwave 3.x compatibility (Decko requires `~> 3.0`)
- A problem specific to production environments or Cloudflare proxying
- A regression introduced in Decko 0.19.x

---

## Environment Specific Issues?

**Cloudflare Configuration:**
- DNS: Orange cloud (proxied)
- SSL: Flexible (HTTPS → Cloudflare → HTTP → Server)
- May affect session cookies or file upload handling

**Production vs Development:**
- Issue may not occur in development (localhost without proxy)
- Set modules might load automatically in development but not production
- Caching behavior might differ

---

## Verification Commands

To verify the issue on this system:

```bash
# SSH into server
ssh -i ~/.ssh/<REDACTED_KEY>.pem ubuntu@<REDACTED_EC2_IP>

# Check cached files exist
ls -lah /home/<user>/<app-dir>/tmp/295/

# Check database actions
cd /home/<user>/<app-dir>
set -a && source .env.production && set +a
PATH="/home/ubuntu/.rbenv/shims:$PATH" script/card console
Card::Action.where(card_id: 295, draft: true).order(id: :desc).limit(5).each { |a| puts "#{a.id}: #{a.comment}" }

# Check logs
tail -100 /home/<user>/<app-dir>/log/production.log | grep "File is missing"
```

---

## Workaround: Console Upload

Until the bug is fixed, files can be uploaded via console:

```bash
# Upload file from local machine to server
scp -i ~/.ssh/<REDACTED_KEY>.pem /path/to/local/file.pdf ubuntu@<REDACTED_EC2_IP>:/tmp/

# Create card via console
ssh -i ~/.ssh/<REDACTED_KEY>.pem ubuntu@<REDACTED_EC2_IP> << 'ENDSSH'
cd /home/<user>/<app-dir>
set -a && source .env.production && set +a
PATH="/home/ubuntu/.rbenv/shims:$PATH" script/card console << 'ENDCONSOLE'
Card::Auth.as_bot do
  Card.create!(
    name: "Neoterics+Metta+metta-and-graphs+file",
    type_id: Card::FileID,
    file: File.open('/tmp/file.pdf')
  )
end
exit
ENDCONSOLE
ENDSSH
```

---

## Next Steps for Investigation

1. **Check Decko GitHub issues** for similar reports
2. **Test in development environment** (no Cloudflare) to isolate proxy issues
3. **Examine `select_file_revision` implementation** in detail
4. **Debug Carrierwave uploader initialization** during cache retrieval
5. **Test with Carrierwave 2.x** to rule out version compatibility
6. **Create minimal reproduction case** for Decko team
7. **File detailed bug report** on GitHub

---

## System Information

```
Decko Version: 0.19.1 (latest as of 2025-10-25)
Carrierwave Version: 3.1.2
Rails Version: 7.2.2.2
Ruby Version: 3.2.3
OS: Ubuntu 22.04.5 LTS
Database: PostgreSQL (AWS RDS)
```

---

## Contact & Resources

- **Decko GitHub**: https://github.com/decko-commons/decko
- **Decko Documentation**: https://decko.org
- **card-mod-carrierwave gem**: https://rubygems.org/gems/card-mod-carrierwave
- **Server**: EC2 <REDACTED_EC2_IP> (ubuntu user)
- **Application**: /home/<user>/<app-dir>
