# Follow-Up Task: Complete reCAPTCHA Bypass for MCP API

**Priority**: High
**Estimated Time**: 30-60 minutes
**Status**: ✅ COMPLETED (2025-12-04 10:09 UTC)
**Actual Time**: ~90 minutes (including troubleshooting)

## Context

The MCP API needs to bypass reCAPTCHA validation for authenticated requests because:
1. JWT authentication already provides strong security
2. reCAPTCHA is meant for preventing bot abuse on public forms
3. API clients cannot solve CAPTCHAs programmatically
4. Web forms should still have reCAPTCHA protection

## Current State

### What's Working
- JWT authentication validates users successfully
- Decko's native `Card::Auth.authenticate()` works correctly
- User accounts are properly extracted from JWT `sub` claim
- An initializer has been created at: `mod/mcp_api/config/initializers/skip_recaptcha_for_api.rb`

### What Needs Fixing
The initializer monkey patches `Card#validate_recaptcha?` but the controller type check needs refinement.

**Current code**:
```ruby
Card.class_eval do
  def validate_recaptcha?
    # Skip if request is coming from MCP API controller
    if Card::Env.controller.is_a?(Api::Mcp::BaseController)
      return false
    end

    # Original logic
    return false unless Card::Codename.exist? :captcha
    !@supercard && !:captcha.card.captcha_used? && recaptcha_on?
  end
end
```

**Issue**: The controller class detection may need to use string comparison or alternative detection method.

## Proposed Solutions

### Option 1: String-Based Controller Class Check (Recommended)
```ruby
Card.class_eval do
  def validate_recaptcha?
    # Skip if request is coming from MCP API controller
    controller = Card::Env.controller
    if controller && controller.class.name.start_with?('Api::Mcp::')
      return false
    end

    # Original logic
    return false unless Card::Codename.exist? :captcha
    !@supercard && !:captcha.card.captcha_used? && recaptcha_on?
  end
end
```

### Option 2: Thread-Local Flag Approach
Set a flag in `BaseController` before each request:

**In base_controller.rb**:
```ruby
before_action :set_mcp_api_flag

private

def set_mcp_api_flag
  Thread.current[:mcp_api_request] = true
end
```

**In initializer**:
```ruby
Card.class_eval do
  def validate_recaptcha?
    # Skip if this is an MCP API request
    return false if Thread.current[:mcp_api_request]

    # Original logic
    return false unless Card::Codename.exist? :captcha
    !@supercard && !:captcha.card.captcha_used? && recaptcha_on?
  end
end
```

### Option 3: Card::Env Attribute Approach
Add a custom attribute to Card::Env:

**In base_controller.rb**:
```ruby
before_action :mark_mcp_request

private

def mark_mcp_request
  Card::Env.instance_variable_set(:@mcp_api, true) if current_account
end
```

**In initializer**:
```ruby
Card.class_eval do
  def validate_recaptcha?
    # Skip if this is an MCP API request
    return false if Card::Env.instance_variable_get(:@mcp_api)

    # Original logic
    return false unless Card::Codename.exist? :captcha
    !@supercard && !:captcha.card.captcha_used? && recaptcha_on?
  end
end
```

## Testing Steps

1. **Test API card creation** (should succeed without reCAPTCHA):
   ```bash
   TOKEN=$(curl -s http://localhost:3000/api/mcp/auth -X POST \
     -H "Content-Type: application/json" \
     -d '{"username":"EMAIL","password":"PASSWORD","role":"user"}' \
     | python3 -c "import sys, json; print(json.load(sys.stdin)['token'])")

   curl -s "http://localhost:3000/api/mcp/cards" -X POST \
     -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"name":"Test reCAPTCHA Bypass","type":"RichText","content":"Success!"}' \
     | python3 -m json.tool
   ```

   **Expected**: 201 Created with card JSON

2. **Test API batch operations** (should succeed):
   ```bash
   curl -s "http://localhost:3000/api/mcp/cards/batch" -X POST \
     -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"ops":[{"action":"create","name":"Batch Test 1","type":"RichText","content":"First"}]}' \
     | python3 -m json.tool
   ```

   **Expected**: 200 OK with results array

3. **Test web form with reCAPTCHA** (should still require CAPTCHA):
   - Navigate to signup or create card form in browser
   - Verify reCAPTCHA widget appears
   - Verify submission without CAPTCHA is blocked

   **Expected**: Web forms still protected by reCAPTCHA

4. **Check production logs for errors**:
   ```bash
   ssh ubuntu@54.219.9.17 "tail -50 magi-archive/log/production.log"
   ```

   **Expected**: No reCAPTCHA-related errors

## Implementation Checklist

- [ ] Choose solution approach (recommend Option 1 or Option 2)
- [ ] Update `mod/mcp_api/config/initializers/skip_recaptcha_for_api.rb`
- [ ] Add before_action to base_controller if using Option 2 or 3
- [ ] Restart server: `sudo systemctl restart magi-archive.service`
- [ ] Test API card creation (should succeed)
- [ ] Test API batch operations (should succeed)
- [ ] Test web form reCAPTCHA (should still be active)
- [ ] Check production logs for errors
- [ ] Update DEPLOYMENT_STATUS.md to mark complete
- [ ] Commit and push changes to feature/mcp-api-phase2 branch

## Success Criteria

- ✅ API requests with valid JWT can create/update cards without reCAPTCHA
- ✅ API batch operations work without reCAPTCHA errors
- ✅ Web forms still show reCAPTCHA widget
- ✅ Web form submissions without CAPTCHA are still blocked
- ✅ No errors in production.log related to reCAPTCHA
- ✅ All previously working tests still pass

## Estimated Timeline

- Implementation: 15-20 minutes
- Testing: 10-15 minutes
- Documentation: 5 minutes
- **Total**: 30-60 minutes

## Notes

- The core issue is that `current_account` (a Card object) doesn't have an `admin?` method
- This is triggered during Decko's permission checking when creating cards
- The initializer approach is cleanest as it doesn't modify Decko's core Auth logic
- Option 1 (string check) is most straightforward and least intrusive
- Option 2 (thread-local) is slightly more complex but very reliable
- Option 3 (instance variable) uses Decko's Env module but requires understanding its lifecycle

## Related Files

- `mod/mcp_api/config/initializers/skip_recaptcha_for_api.rb` - Initializer to fix
- `mod/mcp_api/app/controllers/api/mcp/base_controller.rb` - May need before_action
- `vendor/bundle/ruby/3.2.0/gems/card-mod-recaptcha-0.19.1/set/all/recaptcha.rb` - Reference

---

## ✅ FINAL SOLUTION (Completed 2025-12-04)

### Implementation

**Two-part solution was required**:

1. **reCAPTCHA Bypass Initializer** - String-based controller detection (Option 1)
2. **Account Name Fix** - Strip `+*account` suffix from JWT `sub` claim

### Part 1: Initializer (`skip_recaptcha_for_api.rb`)

```ruby
# frozen_string_literal: true

# Bypass reCAPTCHA for authenticated MCP API requests
# Web forms still require reCAPTCHA validation
Card.class_eval do
  def validate_recaptcha?
    # Skip reCAPTCHA if request is from MCP API controller
    controller = Card::Env.controller
    if controller && controller.class.name.to_s.start_with?('Api::Mcp::')
      Rails.logger.info "MCP API: Skipping reCAPTCHA for #{controller.class.name}"
      return false
    end

    # Original Decko reCAPTCHA validation logic
    return false unless Card::Codename.exist? :captcha

    !@supercard && !:captcha.card.captcha_used? && recaptcha_on?
  end
end
```

**Why this works**:
- Uses string-based controller class name detection
- MCP API controllers are namespaced under `Api::Mcp::`
- Web form controllers use different namespaces (not affected)
- Logging helps with debugging

### Part 2: Account Name Fix (`base_controller.rb` line 60)

**Problem**: JWT `sub` claim contained `"user:Nemquae+*account"` which is a RichText subcard, not the User card. RichText cards don't have the `admin?` method, causing errors.

**Solution**: Strip the `+*account` suffix to get the User card:

```ruby
def find_mcp_account(payload)
  # Extract actual user account from JWT sub claim
  # Format: "user:AccountName" or "user:Username+*account"
  subject = payload["sub"]
  return nil unless subject

  # Extract account name from "user:AccountName" format
  if subject.start_with?("user:")
    account_name = subject.sub(/^user:/, "")
    # Strip +*account suffix to get User card instead of RichText subcard
    account_name = account_name.sub(/\+\*account$/, "")
    account = Card[account_name]
    return account if account
  end

  # Fallback to service accounts if actual user not found
  # ...
end
```

### Test Results

All card write operations now working:

```bash
# Card creation - WORKING ✅
POST /api/mcp/cards
Response: 201 Created, card id: 3415

# Card update - WORKING ✅
PATCH /api/mcp/cards/:name
Response: 200 OK, updated content verified

# Batch operations - WORKING ✅
POST /api/mcp/cards/batch
Response: 200 OK, 2 cards created (ids: 3416, 3417)
```

### Lessons Learned

1. **Controller namespace detection** is more reliable than `is_a?()` checks in Decko's module system
2. **JWT sub claims** may contain subcard names - always strip suffixes like `+*account`
3. **Card types matter** - User cards have different methods than RichText cards
4. **Regex escaping** in Ruby requires careful handling: `/\+\*account$/` not `/+*account$/`
5. **File editing on server** via sed/awk can be tricky - sometimes need intermediate files

### Production Verification

- Server: ubuntu@54.219.9.17
- Branch: feature/mcp-api-phase2
- Tested: 2025-12-04 10:09 UTC
- Status: All write operations working without reCAPTCHA errors ✅
