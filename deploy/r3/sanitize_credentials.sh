#!/bin/bash
# R3 credential sanitization, on the STAGED copy only. Prints counts and setting keys, never a value.
#
# It finds records structurally and never scans card content:
#   - the right part's codename (password, salt, api_key, ...), or a star-setting key matched by an anchored regex;
#   - every descendant of "MCP OAuth Clients", whose records hold encrypted client passwords;
#   - the users table's credential columns, which it sets to NULL.
# A plain-named right part such as "Token" can be ordinary wiki content, so it is never blanked automatically. It is
# reported as a suspect, and --apply refuses until an operator has reviewed them and sets R3_SUSPECTS_REVIEWED=1.
# It removes the values' history (card_changes, card_revisions, card_virtuals), then proves the result with absence
# checks. A dry run does all of this inside a transaction and rolls it back.
#
# Rollback: this touches only the staged database. Drop it and restore from the dump again.
#
# usage: sanitize_credentials.sh [--dry-run|--apply]
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
r3_parse_mode "$@"
r3_load_db_env
r3_assert_target

END_TX=ROLLBACK
[ "$MODE" = apply ] && END_TX=COMMIT
# A dry run only reports suspects. An apply stops on them unless they were reviewed.
SUSPECTS_BLOCK=false
[ "$MODE" = apply ] && [ "${R3_SUSPECTS_REVIEWED:-}" != 1 ] && SUSPECTS_BLOCK=true

r3_psql -q -At -F' | ' <<SQL
\set QUIET on
BEGIN;
-- The cards this pass acts on. Anchored: the whole right-part key must match, so a card merely mentioning a word is safe.
CREATE TEMP TABLE r3_secret ON COMMIT DROP AS
  SELECT c.id, r.key AS right_key
  FROM cards c
  JOIN cards r ON r.id = c.right_id
  WHERE r.codename IN ('password', 'salt', 'api_key', 'token', 'reset_token')
     OR r.key ~ '^\*(api_keys?|oauth[a-z_]*|client_secrets?|secrets?|tokens?|credentials?)\$';
-- OAuth client records are "MCP OAuth Clients+<client_id>". Matched on the stored name of that one simple card.
INSERT INTO r3_secret (id, right_key)
  WITH RECURSIVE tree AS (
    SELECT c.id FROM cards c JOIN cards p ON p.id = c.left_id WHERE lower(p.name) = 'mcp oauth clients'
    UNION
    SELECT c.id FROM cards c JOIN tree t ON c.left_id = t.id
  )
  SELECT id, '<under MCP OAuth Clients>' FROM tree WHERE id NOT IN (SELECT id FROM r3_secret);
-- Plain-named look-alikes: reported, never blanked here. Only the fixed words of this regex can ever be printed.
CREATE TEMP TABLE r3_suspect ON COMMIT DROP AS
  SELECT c.id, r.key AS right_key
  FROM cards c JOIN cards r ON r.id = c.right_id
  WHERE r.key ~ '^(api_keys?|oauth|client_secrets?|secrets?|tokens?|credentials?|passwords?|salts?)\$'
    AND c.id NOT IN (SELECT id FROM r3_secret);
CREATE TEMP TABLE r3_email ON COMMIT DROP AS
  SELECT c.id
  FROM cards c
  JOIN cards r ON r.id = c.right_id AND r.codename = 'email'
  JOIN cards l ON l.id = c.left_id
  JOIN cards a ON a.id = l.right_id AND a.codename = 'account';

\echo === found, by setting key
SELECT right_key, count(*) FROM r3_secret GROUP BY 1 ORDER BY 1;
SELECT 'account emails', count(*) FROM r3_email;
SELECT 'history rows on those cards', count(*) FROM card_changes
  WHERE card_action_id IN (SELECT id FROM card_actions WHERE card_id IN (SELECT id FROM r3_secret UNION SELECT id FROM r3_email));
SELECT 'non-empty secret values', count(*) FROM cards WHERE id IN (SELECT id FROM r3_secret) AND coalesce(db_content, '') <> '';
SELECT 'users rows', count(*) FROM users;
\echo === suspects, plain-named, not blanked
SELECT right_key, count(*) FROM r3_suspect GROUP BY 1 ORDER BY 1;
SELECT 'suspects total', count(*) FROM r3_suspect;
DO \$\$ BEGIN
  IF $SUSPECTS_BLOCK AND EXISTS (SELECT 1 FROM r3_suspect) THEN
    RAISE EXCEPTION 'unreviewed suspects: review them, then set R3_SUSPECTS_REVIEWED=1';
  END IF;
END \$\$;

UPDATE cards SET db_content = '' WHERE id IN (SELECT id FROM r3_secret);
UPDATE cards SET db_content = 'sanitized+' || id || '@invalid.invalid' WHERE id IN (SELECT id FROM r3_email);
DELETE FROM card_changes
  WHERE card_action_id IN (SELECT id FROM card_actions WHERE card_id IN (SELECT id FROM r3_secret UNION SELECT id FROM r3_email));
DELETE FROM card_revisions WHERE card_id IN (SELECT id FROM r3_secret UNION SELECT id FROM r3_email);
DELETE FROM card_virtuals WHERE left_id IN (SELECT id FROM r3_secret UNION SELECT id FROM r3_email)
                             OR right_id IN (SELECT id FROM r3_secret UNION SELECT id FROM r3_email);
UPDATE users SET crypted_password = NULL, salt = NULL, password_reset_code = NULL, email = NULL, login = NULL, identity_url = NULL;
-- Queued jobs and sessions can embed anything, so neither is carried over.
TRUNCATE delayed_jobs;
TRUNCATE sessions;

\echo === absence checks; every count must be 0
SELECT 'secret values left', count(*) FROM cards WHERE id IN (SELECT id FROM r3_secret) AND coalesce(db_content, '') <> '';
SELECT 'emails not sanitized', count(*) FROM cards WHERE id IN (SELECT id FROM r3_email) AND db_content !~ '^sanitized\+[0-9]+@invalid\.invalid\$';
SELECT 'history rows left', count(*) FROM card_changes
  WHERE card_action_id IN (SELECT id FROM card_actions WHERE card_id IN (SELECT id FROM r3_secret UNION SELECT id FROM r3_email));
SELECT 'revision rows left', count(*) FROM card_revisions WHERE card_id IN (SELECT id FROM r3_secret UNION SELECT id FROM r3_email);
SELECT 'users rows with a credential column set', count(*) FROM users
  WHERE crypted_password IS NOT NULL OR salt IS NOT NULL OR password_reset_code IS NOT NULL OR email IS NOT NULL OR login IS NOT NULL OR identity_url IS NOT NULL;
SELECT 'delayed jobs left', count(*) FROM delayed_jobs;
SELECT 'sessions left', count(*) FROM sessions;

DO \$\$ DECLARE bad int; BEGIN
  SELECT (SELECT count(*) FROM cards WHERE id IN (SELECT id FROM r3_secret) AND coalesce(db_content, '') <> '')
       + (SELECT count(*) FROM cards WHERE id IN (SELECT id FROM r3_email) AND db_content !~ '^sanitized\+[0-9]+@invalid\.invalid\$')
       + (SELECT count(*) FROM card_changes WHERE card_action_id IN (SELECT id FROM card_actions WHERE card_id IN (SELECT id FROM r3_secret UNION SELECT id FROM r3_email)))
       + (SELECT count(*) FROM card_revisions WHERE card_id IN (SELECT id FROM r3_secret UNION SELECT id FROM r3_email))
       + (SELECT count(*) FROM users WHERE crypted_password IS NOT NULL OR salt IS NOT NULL OR password_reset_code IS NOT NULL OR email IS NOT NULL OR login IS NOT NULL OR identity_url IS NOT NULL)
    INTO bad;
  IF bad <> 0 THEN RAISE EXCEPTION 'sanitization left % values', bad; END IF;
END \$\$;
$END_TX;
SQL
RC=$?
[ "$RC" = 0 ] || { echo "SANITIZE_FAILED exit=$RC; the transaction was rolled back"; exit 1; }
echo "sanitize finished: mode=$MODE transaction=$END_TX"
