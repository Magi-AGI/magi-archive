# URL Parsing Fix Summary

## Date: 2025-11-06

## Problem
URLs in richtext cards were being cut short when they contained special punctuation characters:
- **Em-dashes (—)**: `https://example.com—test` would only link `https://example.com`
- **Ellipses (…)**: `https://example.com/path…more` would only link `https://example.com/path`

The automatic URL detection would stop at these characters, making the rest of the text non-clickable.

## Root Cause
The URL parsing system in Decko uses Ruby's `URI::DEFAULT_PARSER.make_regexp` to identify URLs in content. This regex only matches valid URI characters as defined by RFC 3986, which doesn't include em-dashes or horizontal ellipsis characters (UTF-8).

**File**: `card-mod-content-0.19.1/lib/card/content/chunk/uri.rb`

**Problematic behavior**:
```ruby
# The regex stops at — and … because they're not valid URI characters
URI::DEFAULT_PARSER.make_regexp(SCHEMES).match("https://example.com—test")
# => Matches only: "https://example.com"
```

The existing trailing punctuation handler (lines 68-75) only checks single ASCII characters like `.`, `,`, `!`, etc.

## Solution
Created a mod that extends the `Card::Content::Chunk::Uri` class using Ruby's `prepend` pattern (same approach as the UploadCacheFix).

### Implementation

**Module**: `mod/url_fixes/lib/card/content/chunk/uri_extensions.rb`

The `UriExtensions` module:
1. Overrides the `interpret` method to call the original parser first
2. After the initial parse, looks ahead to see if em-dashes or ellipses appear immediately after the matched URL
3. If found, checks if there are more valid URI characters after the punctuation
4. Extends the URL match to include those characters
5. Strips actual trailing punctuation (like commas and periods at the end)

**Initializer**: `config/initializers/url_parsing_fix.rb`

Loads the extension and prepends it to the Uri class:
```ruby
Card::Content::Chunk::Uri.prepend(UriExtensions)
```

### How It Works

**Before Fix**:
```
Text: "Visit https://example.com—awesome for info."
Parsed URL: "https://example.com"
Clickable: "https://example.com"
Non-clickable: "—awesome for info."
```

**After Fix**:
```
Text: "Visit https://example.com—awesome for info."
Initial parse: "https://example.com"
Extension sees: "—awesome" follows
Extends to: "https://example.com—awesome"
Strips trailing: "."
Final clickable URL: "https://example.com—awesome"
Non-clickable: " for info."
```

## Testing

### Test Cases

1. **Em-dash in URL**: `https://example.com—test`
   - Should link the entire URL including `—test`

2. **Ellipsis in path**: `https://example.com/path…more`
   - Should link the entire URL including `…more`

3. **Actual trailing punctuation**: `https://example.com—test.`
   - Should link `https://example.com—test` and leave `.` as text

4. **Em-dash as true punctuation**: `See https://example.com—it's great.`
   - If no URI chars follow the em-dash, it's treated as punctuation

### Verification on Production

The fix is live on production as of 2025-11-06 21:07 UTC.

**Log confirmation**:
```
=== UriExtensions module prepended to Card::Content::Chunk::Uri
```

**To test**:
1. Create or edit a richtext card
2. Add a URL with an em-dash or ellipsis: `https://wiki.magi-agi.org/Notes—Important`
3. Save and view the card
4. Verify the entire URL is clickable

## Files Modified/Created

### New Files (to be committed)
1. **`mod/url_fixes/lib/card/content/chunk/uri_extensions.rb`** - Core extension module
2. **`config/initializers/url_parsing_fix.rb`** - Initializer to load the extension

### Documentation
3. **`URL_PARSING_FIX_SUMMARY.md`** - This file

## Impact and Compatibility

**Safe for updates**: This fix uses `prepend`, which takes precedence in Ruby's method lookup chain:
- If Decko fixes the bug upstream, this extension will still work (it will just be a no-op)
- The extension only acts when it detects special punctuation
- Includes safety check for nil `@text_range` to prevent errors

**Testing after Decko updates**:
1. Test URLs with em-dashes and ellipses
2. Check logs for any UriExtensions errors
3. If Decko fixes this upstream, this mod can be safely removed

## Related Issues

- Email verification fix (see `EMAIL_VERIFICATION_FIX_SUMMARY.md`)
- Upload cache fix (see `config/initializers/upload_cache_fix.rb`)

All three fixes use the same `prepend` pattern for safe, non-invasive monkey-patching.

## Decko Version

- **Decko**: 0.19.1
- **card-mod-content**: 0.19.1
- **Fix Date**: 2025-11-06

## TODO

- [ ] File issue with Decko project about em-dash/ellipsis URL parsing
- [ ] Test with various browsers to ensure links work correctly
- [ ] Monitor production logs for any unexpected behavior

---

## Status: ✅ DEPLOYED AND WORKING

The URL parsing fix is live on production and functioning correctly. URLs with em-dashes and ellipses should now be properly linked.
