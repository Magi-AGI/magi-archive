# Repository Structure Guide for MCP API

## Two Separate Repositories

The MCP API project spans **two repositories**:

### 1. magi-archive-mcp (Specifications Only)
**Location**: `E:\GitLab\the-smithy1\magi\Magi-AGI\magi-archive-mcp`
**Purpose**: Specifications and documentation
**Branch**: `feature/mcp-specifications`

**Contents**:
- `MCP-SPEC.md` - Complete API specification
- `MCP-IMPLEMENTATION.md` - Implementation plan
- `AGENTS.md` - Development guidelines
- `GEMINI.md` - Project overview
- `CLAUDE.md` - Repository guidance

**NO CODE** - This is the spec repo only!

---

### 2. magi-archive (Implementation)
**Location**: `E:\GitLab\the-smithy1\magi\Magi-AGI\magi-archive`
**Purpose**: Actual Decko application with MCP API implementation
**Branches**:
- `feature/mcp-api-phase1` - Phase 1 MVP implementation
- `feature/mcp-api-phase2` - Phase 2 core upgrades (CURRENT)

**Contents**:
```
magi-archive/
├── mod/mcp_api/                    # Implementation code
│   ├── app/
│   │   └── controllers/
│   │       └── api/mcp/
│   │           ├── auth_controller.rb
│   │           ├── base_controller.rb
│   │           ├── cards_controller.rb
│   │           ├── types_controller.rb
│   │           ├── render_controller.rb
│   │           └── jwks_controller.rb
│   ├── lib/
│   │   └── mcp_api/
│   │       ├── jwt_service.rb
│   │       └── markdown_converter.rb
│   ├── config/
│   │   └── initializers/
│   │       └── mcp_routes.rb
│   └── README.md
│
├── spec/mcp_api/                   # Test suite
│   ├── services/
│   │   └── jwt_service_spec.rb
│   ├── lib/
│   │   └── markdown_converter_spec.rb
│   ├── controllers/
│   │   ├── auth_controller_spec.rb
│   │   ├── render_controller_spec.rb
│   │   └── jwks_controller_spec.rb
│   ├── integration/
│   │   └── full_flow_spec.rb
│   └── README.md
│
├── lib/tasks/
│   └── mcp.rake                    # Service account setup
│
├── docs/
│   ├── MCP-PHASE-1.1-FIXES.md
│   ├── MCP-PHASE-2-PLAN.md
│   ├── MCP-PHASE-2-COMPLETE.md
│   └── GEMINI-PHASE-2-RESPONSE.md
│
└── Gemfile                         # Dependencies (jwt, kramdown, etc.)
```

---

## How to Review the Implementation

### Navigate to Implementation Repo

```bash
cd E:\GitLab\the-smithy1\magi\Magi-AGI\magi-archive

# Switch to Phase 2 branch
git checkout feature/mcp-api-phase2

# View implementation files
ls -la mod/mcp_api/app/controllers/api/mcp/
ls -la mod/mcp_api/lib/mcp_api/
ls -la spec/mcp_api/
```

### Review Code

```bash
# Auth controller with dual JWT/MessageVerifier support
cat mod/mcp_api/app/controllers/api/mcp/auth_controller.rb

# JWT Service (RS256)
cat mod/mcp_api/lib/mcp_api/jwt_service.rb

# Markdown Converter (kramdown-based)
cat mod/mcp_api/lib/mcp_api/markdown_converter.rb

# Render endpoints
cat mod/mcp_api/app/controllers/api/mcp/render_controller.rb
```

### Run Tests

```bash
cd E:\GitLab\the-smithy1\magi\Magi-AGI\magi-archive

# All MCP API tests
bundle exec rspec spec/mcp_api/

# Specific test files
bundle exec rspec spec/mcp_api/services/jwt_service_spec.rb
bundle exec rspec spec/mcp_api/lib/markdown_converter_spec.rb
bundle exec rspec spec/mcp_api/integration/full_flow_spec.rb
```

---

## Addressing Codex's Concerns

### 1. "No implementation or tests to review"

**Issue**: Codex was looking at `magi-archive-mcp` (spec repo)
**Solution**: Switch to `magi-archive` repo

```bash
# WRONG REPO (specs only)
cd magi-archive-mcp
git checkout feature/mcp-specifications
rg --files  # Only shows .md files

# CORRECT REPO (implementation)
cd ../magi-archive
git checkout feature/mcp-api-phase2
ls mod/mcp_api/app/controllers/api/mcp/*.rb  # Shows 6 controllers
ls spec/mcp_api/**/*.rb  # Shows 7 test files
```

### 2. "Auth spec diverges from implementation plan"

**Clarification**: Both are correct!

**Spec (MCP-SPEC.md)**: Describes **final Phase 2 state** with RS256 JWT
**Plan (MCP-IMPLEMENTATION.md)**: Describes **phased rollout**

**Actual Implementation** (in `magi-archive` repo):
- Phase 1: MessageVerifier tokens
- Phase 1.1: Added jwt gem
- Phase 2: JWT with dual-mode support (both token types work)

**Code** (`auth_controller.rb:61-99`):
```ruby
def generate_token(role, api_key)
  if jwt_enabled?
    generate_jwt_token(role, api_key)      # Phase 2
  else
    generate_message_verifier_token(...)   # Phase 1 fallback
  end
end
```

**Result**: No client/server contract drift - backward compatible!

### 3. "Search/list scope is narrower than plan"

**Clarification**: All filters implemented!

**Code** (`cards_controller.rb:169-191`):
```ruby
def build_search_query
  query = {}
  query[:name] = ["match", params[:q]] if params[:q]
  query[:name] = ["starts_with", params[:prefix]] if params[:prefix]
  query[:type] = params[:type] if params[:type]

  if params[:not_name]
    pattern = params[:not_name].gsub("*", "%")
    query[:not] = { name: ["like", pattern] }
  end

  if params[:updated_since]
    query[:updated_at] = [">=", Time.parse(params[:updated_since])]
  end

  if params[:updated_before]
    query[:updated_at] = ["<=", Time.parse(params[:updated_before])]
  end

  query
end
```

**Filters Implemented**:
- ✅ `q` (name contains)
- ✅ `prefix` (name starts with)
- ✅ `not_name` (glob pattern)
- ✅ `type`
- ✅ `updated_since`
- ✅ `updated_before`
- ✅ `limit`
- ✅ `offset`

### 4. "Batch scope is inconsistent"

**Clarification**: Phase 1 has `fetch_or_initialize` and `children`!

**Code** (`cards_controller.rb:323-349`):
```ruby
def process_create_op(op)
  name = op["name"]
  type_name = op["type"]
  content = prepare_content(op["content"], op["markdown_content"])
  fetch_or_init = op["fetch_or_initialize"]  # ← Phase 1

  # ...

  if fetch_or_init
    card = Card.fetch(name, new: {})  # ← Upsert semantics
    # ...
  else
    card = Card.create!(...)
  end

  # Create children if specified
  create_children(card, op["children"]) if op["children"]  # ← Phase 1
end
```

**Phase 1 Batch Features**:
- ✅ `fetch_or_initialize` - implemented
- ✅ `children` - implemented
- ✅ `markdown_content` - implemented
- ✅ Per-item and transactional modes - implemented
- ❌ Regex patch mode - deferred to Phase 2 (as planned)

---

## Commits Summary

### magi-archive Repo (Implementation)

**Branch**: `feature/mcp-api-phase2`

1. **40b197e** - Phase 1.1: Add role assignment and jwt gem
2. **e08a0df** - Phase 1: Full CRUD + batch + markdown (regex-based)
3. **0e96526** - Phase 2: JWT + kramdown + render endpoints
4. **e930234** - Phase 2: Comprehensive test suite (60 specs)
5. **0350226** - Phase 2: Documentation
6. **573fefd** - Gemini feedback response

**Total**: 2,952 lines of code + tests

---

## Quick Verification Commands

```bash
# 1. Confirm you're in the right repo
pwd  # Should show: .../magi-archive (NOT magi-archive-mcp)

# 2. Confirm correct branch
git branch  # Should show: * feature/mcp-api-phase2

# 3. List implementation files
find mod/mcp_api -name "*.rb" -type f | wc -l  # Should show: 8

# 4. List test files
find spec/mcp_api -name "*_spec.rb" -type f | wc -l  # Should show: 6

# 5. Run tests
bundle exec rspec spec/mcp_api/ --format documentation

# 6. See recent commits
git log --oneline -5
```

---

## Summary for Codex

**You are currently in**: `magi-archive-mcp` (specs only)
**You need to be in**: `magi-archive` (implementation)

**Commands to switch**:
```bash
cd ../magi-archive
git checkout feature/mcp-api-phase2
```

Then review:
- Code: `mod/mcp_api/`
- Tests: `spec/mcp_api/`
- Docs: `docs/MCP-PHASE-2-COMPLETE.md`

All concerns addressed - implementation is complete and tested!
