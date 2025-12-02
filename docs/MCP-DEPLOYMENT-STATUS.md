# MCP API Deployment Status

**Date**: 2025-12-02
**Server**: magi-archive EC2 (54.219.9.17)
**Branch**: feature/mcp-api-phase2
**Commit**: 067ac26

---

## Deployment Summary

The MCP API Phase 2 implementation is **deployed and functional** on the production server. All critical security fixes have been applied and committed.

### ✅ What's Working

1. **Server Status**: Active and running
   - Service: `magi-archive.service`
   - Routes: MCP API endpoints responding
   - Port: 3000

2. **Unit Tests Passing**:
   - JWT Service: 12/12 ✅
   - Markdown Converter: 18/18 ✅

3. **Infrastructure Fixed**:
   - Routes registered before Decko engine mount
   - Controllers inherit from `::ActionController::Base`
   - Manual controller loading in routes.rb
   - Deck runner working with wrapper script

4. **Endpoints Active**:
   - `GET /.well-known/jwks.json` → Requires JWT keys (expected)
   - `POST /auth` → Requires JWT keys (expected)
   - `GET /types` → Requires authentication (working as designed)
   - `GET /cards` → Requires authentication (working as designed)

---

## Security Fixes Applied (Server Only)

### Critical Fixes Committed (067ac26)

1. **BaseController Inheritance** (`base_controller.rb:5`)
   - **Before**: Inherited from ApplicationController
   - **After**: Inherits from ::ActionController::Base
   - **Reason**: Avoid Decko's complex controller hierarchy

2. **CSRF Protection Removed** (`base_controller.rb:8`)
   - **Removed**: skip_before_action :verify_authenticity_token
   - **Reason**: Not defined in ActionController::Base

3. **JWKS Authentication Exemption** (`base_controller.rb:17`)
   - **Before**: Only exempted "auth" controller
   - **After**: Exempts both "auth" and "jwks"
   - **Reason**: JWKS endpoint must be public

4. **JwksController Inheritance** (`jwks_controller.rb:5`)
   - **Before**: Inherited from ApplicationController
   - **After**: Inherits from BaseController
   - **Reason**: Consistency with other MCP controllers

5. **Removed skip_modules** (`cards_controller.rb:147,242`)
   - **Before**: Card.fetch(name, skip_modules: true)
   - **After**: Card.fetch(name)
   - **Reason**: Attribute doesn't exist in current Card version

6. **Child Card Permission Context** (`cards_controller.rb:392-400`)
   - **Before**: Card.create!(...) without permission context
   - **After**: Wrapped in Card::Auth.as(current_account.name)
   - **Reason**: Enforce service account permissions for child creation

7. **Routes in Main Config** (`config/routes.rb:4-46`)
   - **Location**: Moved from mod/mcp_api/config/initializers/ to config/routes.rb
   - **Position**: Before Decko::Engine mount to take precedence
   - **Loading**: Manual controller requires to avoid autoload issues

8. **Markdown Converter Security** (`markdown_converter.rb:83-111`)
   - **Sanitization**: Rails sanitizer with explicit allowlists
   - **Placeholders**: Changed to WIKILINKNENDWIKI (no escaping)
   - **Parser**: Switched from GFM to kramdown (no extra gem needed)

---

## Configuration Required

The only blocker to full functionality is **JWT key configuration**:

### Generate JWT Keys

```bash
cd /home/ubuntu/magi-archive
openssl genrsa -out config/jwt_private.pem 2048
openssl rsa -in config/jwt_private.pem -pubout -out config/jwt_public.pem
chmod 600 config/jwt_private.pem
```

### Update Environment Variables

Add to `/home/ubuntu/magi-archive/.env.production`:

```bash
JWT_PRIVATE_KEY_PATH=/home/ubuntu/magi-archive/config/jwt_private.pem
JWT_PUBLIC_KEY_PATH=/home/ubuntu/magi-archive/config/jwt_public.pem
JWT_KEY_ID=prod-key-001
JWT_ISSUER=magi-archive
MCP_JWT_ENABLED=true
MCP_API_KEY=<generate-secure-key>
```

### Restart Service

```bash
sudo systemctl restart magi-archive
```

---

## Testing the Deployment

### Using the Smoke Test Script

Once JWT keys are configured:

```bash
cd /home/ubuntu/magi-archive
export MCP_API_KEY="your-api-key"
bin/smoke_test_mcp.rb
```

Expected output:
```
✓ JWKS Endpoint (Public)
  JWKS structure valid
✓ Authentication
  Token received
✓ Types Endpoint
  Found 50+ types
```

### Manual Endpoint Testing

```bash
# Test JWKS (should return JWT public keys after config)
curl http://localhost:3000/api/mcp/.well-known/jwks.json

# Test auth (should return JWT token)
curl -X POST http://localhost:3000/api/mcp/auth \
  -H "Content-Type: application/json" \
  -d '{"api_key":"YOUR_API_KEY","role":"user"}'

# Test types (should require Bearer token)
curl http://localhost:3000/api/mcp/types \
  -H "Authorization: Bearer YOUR_JWT_TOKEN"
```

---

## Deck Runner Usage

A wrapper script is available for Codex/Gemini to run card operations:

```bash
/home/ubuntu/run-card-runner.sh 'Ruby code here'
```

**Example**:
```bash
/home/ubuntu/run-card-runner.sh 'puts "Cards: #{Card.count}"'
# Output: Cards: 3085
```

**Update a card**:
```bash
/home/ubuntu/run-card-runner.sh '
  card = Card.fetch("Business Plan+Gaming Cooperative Resources")
  card.content += "\n\nNew addendum content"
  card.save!
  puts "Updated: #{card.name}"
'
```

---

## File Locations

### Key Files Modified on Server

- `config/routes.rb` - MCP routes registered
- `mod/mcp_api/app/controllers/api/mcp/base_controller.rb` - Fixed inheritance
- `mod/mcp_api/app/controllers/api/mcp/cards_controller.rb` - Fixed permissions
- `mod/mcp_api/app/controllers/api/mcp/jwks_controller.rb` - Fixed inheritance
- `mod/mcp_api/lib/mcp_api/markdown_converter.rb` - Fixed sanitization
- `/home/ubuntu/run-card-runner.sh` - Wrapper for deck runner

### New Files Created

- `bin/smoke_test_mcp.rb` - API verification script
- `spec/support/decko_bootstrap.rb` - Test constant stubs
- `mod/mcp_api/lib/mcp_api/engine.rb` - Rails engine (attempted, not used)

---

## Git Status

**Branch**: `feature/mcp-api-phase2`
**Last Commit**: 067ac26 "Fix MCP API deployment issues"
**Files Changed**: 19 files, 2605 insertions, 25 deletions

All server-side fixes have been committed to git. To pull changes to local repo:

```bash
cd magi-archive-mcp  # or appropriate local path
git fetch origin
git checkout feature/mcp-api-phase2
git pull origin feature/mcp-api-phase2
```

---

## Next Steps

1. **Generate JWT Keys** - Run the openssl commands above
2. **Configure Environment** - Update `.env.production` with JWT paths
3. **Restart Server** - `sudo systemctl restart magi-archive`
4. **Run Smoke Tests** - `bin/smoke_test_mcp.rb`
5. **Document API Key** - Store `MCP_API_KEY` securely for client use

---

## References

- **Security Audit**: `docs/FINAL-SECURITY-AUDIT.md`
- **API Spec**: `MCP-SPEC.md`
- **Implementation**: `docs/MCP-PHASE-2-COMPLETE.md`
- **This Status**: `docs/MCP-DEPLOYMENT-STATUS.md`
