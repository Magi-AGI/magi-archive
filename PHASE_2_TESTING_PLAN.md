# Phase 2 Testing Plan

**Date**: 2025-12-04
**Status**: Ready for Execution
**Prerequisites**: Working authentication credentials

---

## Overview

This document provides step-by-step testing procedures for all Phase 2 validation and render endpoints after bug fixes were applied.

## Bugs Fixed (Awaiting Verification)

1. **validate_structure** - Fixed RegexpError by adding `child_pattern_to_regex()` helper
2. **suggest_improvements** - Fixed NoMethodError by using `Card.where(left_id:)` instead of `card.children`

---

## Testing Procedures

### Prerequisites

```bash
# Get authentication token
TOKEN=$(curl -s http://localhost:3000/api/mcp/auth -X POST \
  -H "Content-Type: application/json" \
  -d '{"username":"VALID_USERNAME","password":"VALID_PASSWORD","role":"user"}' \
  | python3 -c "import sys, json; print(json.load(sys.stdin)['token'])")

echo "Token: $TOKEN"
```

### Test 1: Validate Structure (Previously Failing)

**Expected**: Should now work without RegexpError

```bash
curl -s "http://localhost:3000/api/mcp/validation/structure" -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "Character",
    "name": "Test Character",
    "has_children": true,
    "children_names": ["Test Character+background", "Test Character+stats"]
  }' | python3 -m json.tool
```

**Expected Response**:
```json
{
  "valid": true,
  "errors": [],
  "warnings": ["Consider adding suggested child cards: *inventory"],
  "required_children": [],
  "suggested_children": ["*background", "*stats", "*inventory"],
  "has_children": true
}
```

**Verification**:
- ✅ No RegexpError
- ✅ Returns valid JSON structure
- ✅ Correctly identifies matching children
- ✅ Suggests missing children

### Test 2: Suggest Improvements (Previously Failing)

**Expected**: Should now work without NoMethodError

```bash
# First create a test card if needed
curl -s "http://localhost:3000/api/mcp/cards" -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Test Character For Validation",
    "type": "RichText",
    "content": "A test character card"
  }' | python3 -m json.tool

# Then test suggestions
curl -s "http://localhost:3000/api/mcp/validation/suggest_improvements" -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Test Character For Validation"
  }' | python3 -m json.tool
```

**Expected Response**:
```json
{
  "card_name": "Test Character For Validation",
  "card_type": "RichText",
  "missing_children": [],
  "missing_tags": [],
  "suggested_additions": [
    {
      "pattern": "*background",
      "suggestion": "Test Character For Validation+background",
      "priority": "suggested"
    },
    {
      "pattern": "*stats",
      "suggestion": "Test Character For Validation+stats",
      "priority": "suggested"
    }
  ],
  "naming_issues": [],
  "summary": "2 suggested additions"
}
```

**Verification**:
- ✅ No NoMethodError
- ✅ Returns valid JSON structure
- ✅ Correctly checks existing children using left_id
- ✅ Suggests appropriate additions

### Test 3: Validate Tags

**Status**: Already working (tested in previous session)

```bash
curl -s "http://localhost:3000/api/mcp/validation/tags" -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "Character",
    "tags": ["Game", "Character"],
    "content": "A test character"
  }' | python3 -m json.tool
```

**Expected**: Valid response with tag recommendations

### Test 4: Get Requirements

**Status**: Already working (tested in previous session)

```bash
curl -s "http://localhost:3000/api/mcp/validation/requirements/Character" \
  -H "Authorization: Bearer $TOKEN" | python3 -m json.tool
```

**Expected**: Returns required and suggested tags/children for Character type

### Test 5: Recommend Structure

**Status**: Already working (tested in previous session)

```bash
curl -s "http://localhost:3000/api/mcp/validation/recommend_structure" -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "Character",
    "name": "New Character",
    "tags": ["Game", "Character"],
    "content": "A new character for testing"
  }' | python3 -m json.tool
```

**Expected**: Returns comprehensive recommendations for card structure

### Test 6: HTML to Markdown Conversion

**Status**: Already working (tested in previous session)

```bash
curl -s "http://localhost:3000/api/mcp/render/" -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "html": "<h1>Title</h1><p>Content with [[Wiki Link]] and [[Link|Display]].</p>"
  }' | python3 -m json.tool
```

**Expected**: Returns Markdown with preserved wiki links

### Test 7: Markdown to HTML Conversion

**Status**: Already working (tested in previous session)

```bash
curl -s "http://localhost:3000/api/mcp/render/markdown" -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "markdown": "# Title\n\nContent with [[Wiki Link]] and **bold**."
  }' | python3 -m json.tool
```

**Expected**: Returns HTML with preserved wiki links and proper formatting

---

## Edge Case Testing

### Test 8: Structure Validation with No Children

```bash
curl -s "http://localhost:3000/api/mcp/validation/structure" -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "Character",
    "name": "Lone Character",
    "has_children": false,
    "children_names": []
  }' | python3 -m json.tool
```

**Expected**: Should suggest child cards but not error

### Test 9: Suggest Improvements for Card with Children

```bash
# Create parent card
curl -s "http://localhost:3000/api/mcp/cards" -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Parent Card Test",
    "type": "RichText",
    "content": "Parent card"
  }' | python3 -m json.tool

# Create child card
curl -s "http://localhost:3000/api/mcp/cards" -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Parent Card Test+background",
    "type": "RichText",
    "content": "Child card"
  }' | python3 -m json.tool

# Check suggestions
curl -s "http://localhost:3000/api/mcp/validation/suggest_improvements" -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Parent Card Test"
  }' | python3 -m json.tool
```

**Expected**: Should correctly identify existing children and suggest additional ones

### Test 10: Pattern Matching with Special Characters

```bash
curl -s "http://localhost:3000/api/mcp/validation/structure" -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "Character",
    "name": "Complex+Name+Test",
    "has_children": true,
    "children_names": ["Complex+Name+Test+background"]
  }' | python3 -m json.tool
```

**Expected**: Should handle complex card names with multiple `+` characters

---

## Validation Checklist

### Phase 2 Validation Endpoints
- [ ] POST /validation/tags - Tag validation working
- [ ] POST /validation/structure - Structure validation working (NO RegexpError)
- [ ] GET /validation/requirements/:type - Type requirements working
- [ ] POST /validation/recommend_structure - Recommendations working
- [ ] POST /validation/suggest_improvements - Suggestions working (NO NoMethodError)

### Phase 2 Render Endpoints
- [ ] POST /render/ (HTML to Markdown) - Conversion working, wiki links preserved
- [ ] POST /render/markdown (Markdown to HTML) - Conversion working, wiki links preserved

### Bug Fixes Verified
- [ ] No RegexpError when validating structure with `*pattern` children
- [ ] No NoMethodError when suggesting improvements (uses Card.where(left_id:))
- [ ] Child pattern regex correctly matches "CardName+suffix"
- [ ] Existing children correctly identified via left_id foreign key

---

## Success Criteria

✅ **All tests pass**:
- No 500 Internal Server Errors
- No RegexpError exceptions
- No NoMethodError exceptions
- All endpoints return valid JSON
- Wiki links preserved in render operations
- Child card patterns correctly matched

✅ **Performance acceptable**:
- All endpoints respond within 500ms
- No memory leaks or resource issues

✅ **Documentation complete**:
- PHASE_2_IMPLEMENTATION.md updated
- COMPREHENSIVE_TEST_REPORT.md updated
- All changes committed to Git

---

## Authentication Note

**Current Status**: Authentication temporarily unavailable during testing session
**Action Required**: Re-run all tests with valid credentials once authentication is restored

If authentication continues to fail:
1. Check if password has changed
2. Verify account is not locked
3. Check Decko's Card::Auth system is working
4. Try creating a new test account
5. Check production logs for detailed error messages

---

## Files Modified

1. `mod/mcp_api/app/controllers/api/mcp/validation_controller.rb`
   - Lines 140-155: Used child_pattern_to_regex in perform_structure_validation
   - Lines 382-390: Fixed existing_children lookup using Card.where(left_id:)
   - Lines 409-428: Used child_pattern_to_regex in analyze_card_and_suggest_improvements
   - Lines 546-563: Added child_pattern_to_regex helper method

2. `config/routes.rb` (from previous session)
   - Changed namespace to scope for validation routes
   - Changed namespace to scope for render routes

3. `mod/mcp_api/app/controllers/api/mcp/cards_controller.rb` (from previous session)
   - Lines 100-120: Fixed children endpoint using Card.where(left_id:)

---

**Next Steps**: Execute this testing plan once authentication credentials are available, then update COMPREHENSIVE_TEST_REPORT.md with results.
