#!/bin/bash
# Proves the R3 scripts against disposable local databases and files only, inside the local containers. Real exit codes.
# Nothing here reaches the dev host or production.
L=$(cd "$(dirname "$0")" && pwd)
if [ -f "$L/../lib.sh" ]; then
  R3=$(cd "$L/.." && pwd)
else
  R3=/work/_internal_handoffs/magi-workflow-v1-recording-prep/mirror-port-preparation/dev-runner/r3
fi
echo "scripts under test: $R3"
APP=/work/_wt-magi-archive-mirror-port
export RAILS_ENV=test DB_HOST=pg DB_USERNAME=magi DATABASE_PASSWORD=disposable PGPASSWORD=disposable
export GO=replace-dev-db-with-strict-filtered-prod-copy
FAILS=0
A() { psql -h pg -U magi -d postgres -v ON_ERROR_STOP=1 -q -At -c "$1"; }
Q() { psql -h pg -U magi -d impl6_r3_staged -q -At -c "$1"; }
C() { psql -h pg -U magi -d impl6_r3_capture -q -At -c "$1"; }
P() { psql -h pg -U magi -d impl6_r3_partial_staged -q -At -c "$1"; }
# A fingerprint of everything these scripts may touch. Hash only; no value is printed.
fp() { Q "SELECT md5(string_agg(x, '|' ORDER BY x)) FROM (SELECT 'c'||id||md5(coalesce(db_content,'')) x FROM cards UNION ALL SELECT 'ch'||id FROM card_changes UNION ALL SELECT 'u'||id||md5(coalesce(crypted_password,'')||coalesce(email,'')) FROM users UNION ALL SELECT 's'||id FROM sessions UNION ALL SELECT 'j'||id FROM delayed_jobs UNION ALL SELECT 'r'||id FROM card_revisions) t"; }
# expect <label> <wanted-exit: 0, or N for a refusal> <command...>
expect() {
  local label=$1 want=$2; shift 2
  echo; echo "=== $label"; echo "\$ $*"
  "$@"; local rc=$?
  echo "real exit=$rc (wanted $want)"
  if [ "$rc" != "$want" ]; then FAILS=$((FAILS + 1)); echo "TEST FAIL: $label"; fi
}
# Unchanged-state check after something that must not change anything.
same() { local after; after=$(fp); if [ "$1" = "$after" ]; then echo "PASS state unchanged: $2"; else FAILS=$((FAILS + 1)); echo "TEST FAIL state changed: $2"; fi; }
# Like expect, and keeps the output, so a test can assert WHY a command exited as it did, not only the exit code.
LAST=/tmp/r3_last_output
expect_out() {
  local label=$1 want=$2; shift 2
  echo; echo "=== $label"; echo "\$ $*"
  "$@" > "$LAST" 2>&1; local rc=$?
  cat "$LAST"
  echo "real exit=$rc (wanted $want)"
  if [ "$rc" != "$want" ]; then FAILS=$((FAILS + 1)); echo "TEST FAIL: $label"; fi
}
has() { if grep -qE -- "$1" "$LAST"; then echo "PASS output has: $1"; else FAILS=$((FAILS + 1)); echo "TEST FAIL output lacks: $1"; fi; }
lacks() { if grep -qE -- "$1" "$LAST"; then FAILS=$((FAILS + 1)); echo "TEST FAIL output has: $1"; else echo "PASS output lacks: $1"; fi; }
# A clean refusal: the script's own message, no backtrace, and no check ran first.
clean_refusal() { has "^REFUSED: $1"; lacks 'from /'; lacks '^(PASS|FAIL) '; }
is() { if [ "$2" = "$3" ]; then echo "PASS $1: $2"; else FAILS=$((FAILS + 1)); echo "TEST FAIL $1: got '$2', wanted '$3'"; fi; }

echo "--- setup: disposable databases"
A "DROP DATABASE IF EXISTS impl6_r3_staged"; A "DROP DATABASE IF EXISTS impl6_r3_capture"
A "DROP DATABASE IF EXISTS magi_probe_notstaged"
A "CREATE DATABASE impl6_r3_staged TEMPLATE magi_archive_test"
A "CREATE DATABASE impl6_r3_capture TEMPLATE magi_archive_test"
A "CREATE DATABASE magi_probe_notstaged TEMPLATE magi_archive_test"
cd "$APP" || exit 99
DATABASE_URL="postgresql://magi@pg/impl6_r3_capture" bundle _2.7.2_ exec decko runner "$L/e_setup_fixture.rb" 2>/dev/null; FX=$?; echo "fixture exit=$FX"
[ "$FX" = 0 ] || { FAILS=$((FAILS + 1)); echo "TEST FAIL fixture setup"; }
# Synthetic credential data in the staged copy: made-up values, including history, a users row, and a look-alike.
Q "INSERT INTO users (card_id, account_id, email, crypted_password, salt, login) VALUES (1,1,'made-up@example.invalid','made-up-hash','made-up-salt','made-up')"
Q "INSERT INTO sessions (session_id, data) VALUES ('made-up','made-up')"
Q "INSERT INTO cards (name, key, db_content, trash, left_id, right_id, type_id, read_rule_id, read_rule_class, creator_id, updater_id, created_at, updated_at)
   SELECT '', '', 'made-up-oauth-secret', false, p.id, 215, 3, 1, '*all', 1, 1, now(), now() FROM (SELECT id FROM cards LIMIT 1) p WHERE false"
Q "WITH o AS (INSERT INTO cards (name, key, db_content, trash, type_id, creator_id, updater_id, created_at, updated_at)
     SELECT 'MCP OAuth Clients','mcp_o_auth_client','',false,type_id,creator_id,updater_id,now(),now() FROM cards WHERE codename='account' RETURNING id),
   k AS (INSERT INTO cards (name, key, db_content, trash, type_id, creator_id, updater_id, created_at, updated_at)
     SELECT 'madeupclient','madeupclient','',false,type_id,creator_id,updater_id,now(),now() FROM cards WHERE codename='account' RETURNING id),
   t AS (INSERT INTO cards (name, key, db_content, trash, type_id, creator_id, updater_id, created_at, updated_at)
     SELECT 'Token','token','',false,type_id,creator_id,updater_id,now(),now() FROM cards WHERE codename='account' RETURNING id)
   INSERT INTO cards (left_id, right_id, db_content, trash, type_id, creator_id, updater_id, created_at, updated_at)
     SELECT o.id, k.id, 'made-up-oauth-client-json', false, c.type_id, c.creator_id, c.updater_id, now(), now() FROM o, k, cards c WHERE c.codename='account'
     UNION ALL
     SELECT t.id, k.id, 'x', false, c.type_id, c.creator_id, c.updater_id, now(), now() FROM t, k, cards c WHERE false
     UNION ALL
     SELECT k.id, t.id, 'ordinary wiki text', false, c.type_id, c.creator_id, c.updater_id, now(), now() FROM t, k, cards c WHERE c.codename='account'"
echo "fixture counts: password cards with a value=$(Q "SELECT count(*) FROM cards c JOIN cards r ON r.id=c.right_id WHERE r.codename='password' AND coalesce(c.db_content,'')<>''") users=$(Q "SELECT count(*) FROM users")"

export R3_LOCAL_TEST=1 R3_STAGED_DB=impl6_r3_staged
unset R3_GO
F0=$(fp)

echo; echo "################ GATE REFUSALS: exit non-zero and nothing changes"
expect "sanitize --apply without R3_GO refuses" 2 bash "$R3/sanitize_credentials.sh" --apply
same "$F0" "sanitize without R3_GO"
expect "sanitize --apply with a wrong R3_GO refuses" 2 env R3_GO=yes bash "$R3/sanitize_credentials.sh" --apply
same "$F0" "sanitize with a wrong R3_GO"
expect "sanitize on a database not named *_staged refuses, even with R3_GO" 2 env R3_GO=$GO R3_STAGED_DB=magi_probe_notstaged bash "$R3/sanitize_credentials.sh" --apply
expect "sanitize on magi_archive_production refuses, even with R3_GO" 2 env R3_GO=$GO R3_STAGED_DB=magi_archive_production bash "$R3/sanitize_credentials.sh" --apply
expect "the local-test override is refused against any other database host" 2 env R3_GO=$GO DB_HOST=some-other-host bash "$R3/sanitize_credentials.sh" --apply
printf 'DB_HOST=magi-archive-dev.fake.invalid\nDB_USERNAME=magi\nDATABASE_PASSWORD=disposable\n' > /tmp/r3_fake.env
expect "without the override, a host that cannot prove it is the dev instance refuses" 2 env -u R3_LOCAL_TEST R3_ENV_FILE=/tmp/r3_fake.env R3_GO=$GO bash "$R3/sanitize_credentials.sh" --apply
printf 'DB_HOST=magi-archive-db.fake.invalid\nDB_USERNAME=magi\nDATABASE_PASSWORD=disposable\n' > /tmp/r3_fake2.env
expect "without the override, a production-looking DB_HOST refuses" 2 env -u R3_LOCAL_TEST R3_ENV_FILE=/tmp/r3_fake2.env R3_GO=$GO bash "$R3/sanitize_credentials.sh" --apply
same "$F0" "all target refusals"
expect "attachments --apply without R3_GO refuses" 2 bash "$R3/remove_attachments.sh" --apply
expect "restore --apply without R3_GO refuses" 2 bash "$R3/run_ruby.sh" restore --apply
expect "capture --apply without R3_GO refuses" 2 bash "$R3/run_ruby.sh" capture --apply
expect "probes have no --apply" 2 env R3_GO=$GO bash "$R3/run_ruby.sh" probes --apply
same "$F0" "all script-gate refusals"

echo; echo "################ ATTACHMENTS"
rm -rf /tmp/r3att; mkdir -p /tmp/r3att/store/111 /tmp/r3att/store/~222 /tmp/r3att/store/333 /tmp/r3att/public/~111
echo made-up > /tmp/r3att/store/111/a; echo made-up > /tmp/r3att/store/~222/b; echo keep > /tmp/r3att/store/333/c; echo made-up > /tmp/r3att/public/~111/d
echo '{"attachment_card_ids":[111,222,999]}' > /tmp/r3att/m.json
echo '{"attachment_card_ids":[111,"../../etc"]}' > /tmp/r3att/bad.json
export R3_FILES_DIR=/tmp/r3att/store R3_PUBLIC_FILES_DIR=/tmp/r3att/public
expect "attachments: a manifest with a non-integer id refuses" 2 env R3_MANIFEST=/tmp/r3att/bad.json bash "$R3/remove_attachments.sh"
echo 'not json{' > /tmp/r3att/notjson.json; echo '{"other":[1]}' > /tmp/r3att/nokey.json; echo '{"attachment_card_ids":5}' > /tmp/r3att/notlist.json
expect_out "attachments with R3_MANIFEST unset refuse" 2 env -u R3_MANIFEST bash "$R3/remove_attachments.sh"
has '^REFUSED: R3_MANIFEST is not set'
for bad in notjson nokey notlist; do
  expect_out "attachments with a bad manifest ($bad) refuse" 2 env R3_MANIFEST=/tmp/r3att/$bad.json bash "$R3/remove_attachments.sh"
  has '^REFUSED: the manifest is malformed'
  lacks 'Traceback'
  lacks 'not json'
done
expect "attachments dry run" 0 env R3_MANIFEST=/tmp/r3att/m.json bash "$R3/remove_attachments.sh"
[ -d /tmp/r3att/store/111 ] && echo "PASS dry run moved nothing" || { FAILS=$((FAILS+1)); echo "TEST FAIL dry run moved something"; }
expect "attachments apply (fixture files)" 0 env R3_GO=$GO R3_MANIFEST=/tmp/r3att/m.json R3_HOLDING=/tmp/r3att/hold bash "$R3/remove_attachments.sh" --apply
[ ! -e /tmp/r3att/store/111 ] && [ ! -e /tmp/r3att/store/~222 ] && [ ! -e /tmp/r3att/public/~111 ] && [ -d /tmp/r3att/store/333 ] && echo "PASS listed ids moved, unlisted id kept" || { FAILS=$((FAILS+1)); echo "TEST FAIL move result"; }
echo "holding dir mode: $(stat -c %a /tmp/r3att/hold)"
expect "attachments rollback" 0 bash /tmp/r3att/hold/rollback.sh
[ -f /tmp/r3att/store/111/a ] && [ -f /tmp/r3att/store/~222/b ] && [ -f /tmp/r3att/public/~111/d ] && echo "PASS rollback restored every file" || { FAILS=$((FAILS+1)); echo "TEST FAIL rollback"; }
unset R3_PUBLIC_FILES_DIR

echo; echo "################ SANITIZATION"
expect "sanitize dry run" 0 bash "$R3/sanitize_credentials.sh" --dry-run
same "$F0" "sanitize dry run rolled back"
expect "sanitize apply stops on unreviewed suspects" 1 env R3_GO=$GO bash "$R3/sanitize_credentials.sh" --apply
same "$F0" "suspect refusal rolled back"
expect "sanitize apply on the disposable copy" 0 env R3_GO=$GO R3_SUSPECTS_REVIEWED=1 bash "$R3/sanitize_credentials.sh" --apply
echo "--- independent absence checks, not using the script's own queries"
v=$(Q "SELECT count(*) FROM cards c JOIN cards r ON r.id=c.right_id WHERE r.codename IN ('password','salt','api_key') AND coalesce(c.db_content,'')<>''"); echo "secret values left: $v"; [ "$v" = 0 ] || { FAILS=$((FAILS+1)); echo "TEST FAIL secrets left"; }
v=$(Q "SELECT count(*) FROM cards WHERE db_content LIKE '%made-up-oauth%'"); echo "made-up oauth values left: $v"; [ "$v" = 0 ] || { FAILS=$((FAILS+1)); echo "TEST FAIL oauth left"; }
v=$(Q "SELECT count(*) FROM cards WHERE db_content = 'ordinary wiki text'"); echo "look-alike kept (must be 1): $v"; [ "$v" = 1 ] || { FAILS=$((FAILS+1)); echo "TEST FAIL look-alike was blanked"; }
v=$(Q "SELECT count(*) FROM users WHERE crypted_password IS NOT NULL OR salt IS NOT NULL OR email IS NOT NULL OR login IS NOT NULL"); echo "users credential columns set: $v"; [ "$v" = 0 ] || { FAILS=$((FAILS+1)); echo "TEST FAIL users"; }
v=$(Q "SELECT count(*) FROM sessions"); echo "sessions: $v"; [ "$v" = 0 ] || { FAILS=$((FAILS+1)); echo "TEST FAIL sessions"; }

echo; echo "################ DEV PRESERVATION"
export R3_APP_DIR=$APP R3_PRESERVE_FILE=/tmp/r3_preserve.json R3_MAP_FILE=/tmp/r3_map.json R3_CAPTURE_DB=impl6_r3_capture
export R3_DEV_ACCOUNTS="R3 Fixture User" R3_DEV_NAV_CARDS="R3 Fixture Nav"
rm -f /tmp/r3_preserve.json /tmp/r3_map.json
expect_out "capture without R3_DEV_ACCOUNTS refuses" 2 env -u R3_DEV_ACCOUNTS bash "$R3/run_ruby.sh" capture --dry-run
clean_refusal 'name the dev accounts'
expect "capture dry run writes nothing" 0 bash "$R3/run_ruby.sh" capture --dry-run
[ ! -e /tmp/r3_preserve.json ] && echo "PASS no capture file written" || { FAILS=$((FAILS+1)); echo "TEST FAIL capture wrote a file"; }
expect "capture apply (fixture data)" 0 env R3_GO=$GO bash "$R3/run_ruby.sh" capture --apply
echo "capture file mode: $(stat -c %a /tmp/r3_preserve.json)"
ACCOUNT_PART="FROM cards c JOIN cards r ON r.id=c.right_id JOIN cards l ON l.id=c.left_id JOIN cards u ON u.id=l.left_id WHERE u.name='R3 Fixture User'"
for part in password salt; do
  SOURCE_VALUE=$(C "SELECT c.db_content $ACCOUNT_PART AND r.codename='$part'")
  if [ -z "$SOURCE_VALUE" ]; then FAILS=$((FAILS+1)); echo "TEST FAIL the source account has no stored $part value to compare against";
  elif grep -qF -- "$SOURCE_VALUE" /tmp/r3_preserve.json; then FAILS=$((FAILS+1)); echo "TEST FAIL capture holds the source account's stored $part value";
  else echo "PASS capture does not hold the source account's stored $part value (compared, not printed)"; fi
done
for w in crypted salt; do
  grep -qi "$w" /tmp/r3_preserve.json && { FAILS=$((FAILS+1)); echo "TEST FAIL capture holds '$w'"; } || echo "PASS capture holds no '$w'"
done
is "capture recorded the fixture user's role" "$(python3 -c "import json; print('Shark' in json.load(open('/tmp/r3_preserve.json'))['accounts'][0]['roles'])")" True
F1=$(fp)
echo; echo "--- restore inputs: a clean refusal, and nothing changes"
echo 'not json{' > /tmp/r3_bad.json
echo '["not","a","capture"]' > /tmp/r3_wrong_shape.json
expect_out "restore with a preservation file that does not exist refuses" 2 env R3_GO=$GO R3_PRESERVE_FILE=/tmp/r3_no_such_file.json bash "$R3/run_ruby.sh" restore --apply
clean_refusal 'R3_PRESERVE_FILE'
expect_out "restore with a malformed preservation file refuses" 2 env R3_GO=$GO R3_PRESERVE_FILE=/tmp/r3_bad.json bash "$R3/run_ruby.sh" restore --apply
clean_refusal 'R3_PRESERVE_FILE'
lacks 'not json'
expect_out "restore with a preservation file of the wrong shape refuses" 2 env R3_GO=$GO R3_PRESERVE_FILE=/tmp/r3_wrong_shape.json bash "$R3/run_ruby.sh" restore --apply
clean_refusal 'R3_PRESERVE_FILE'
expect_out "restore --apply with no reference-map path refuses before it commits anything" 2 env -u R3_MAP_FILE R3_GO=$GO bash "$R3/run_ruby.sh" restore --apply
clean_refusal 'R3_MAP_FILE'
expect_out "restore --apply with an unwritable reference-map path refuses before it commits anything" 2 env R3_MAP_FILE=/tmp/r3_no_such_dir/map.json R3_GO=$GO bash "$R3/run_ruby.sh" restore --apply
clean_refusal 'R3_MAP_FILE'
same "$F1" "restore input refusals"
SEQ_BEFORE=$(Q "SELECT last_value || '/' || is_called FROM cards_id_seq")
expect_out "restore dry run rolls back" 0 bash "$R3/run_ruby.sh" restore --dry-run
is "the dry run left the card id sequence where it was" "$(Q "SELECT last_value || '/' || is_called FROM cards_id_seq")" "$SEQ_BEFORE"
has '^RESTORE created=4 skipped_existing=2 apply=false$'
has '^mail delivery: off$'
has '^dry run: rolled back; no reference map written$'
same "$F1" "restore dry run"
[ ! -e /tmp/r3_map.json ] && echo "PASS dry run wrote no reference map" || { FAILS=$((FAILS+1)); echo "TEST FAIL dry run wrote a reference map"; }
expect_out "restore apply on the disposable copy" 0 env R3_GO=$GO bash "$R3/run_ruby.sh" restore --apply
has '^RESTORE created=4 skipped_existing=2 apply=true$'
has '^mail delivery: off$'
lacks 'from /'
has '^reference map written: 4 entries, mode 600$'
lacks 'R3-[0-9a-f]{48}'
lacks 'fixture-user@example'
is "reference map file mode" "$(stat -c %a /tmp/r3_map.json 2>/dev/null)" 600
is "reference map entries" "$(python3 -c "import json; print(len(json.load(open('/tmp/r3_map.json'))))" 2>/dev/null)" 4
is "reference map entries that kept their old id" "$(python3 -c "import json; print(sum(1 for k,v in json.load(open('/tmp/r3_map.json')).items() if int(k)==int(v)))" 2>/dev/null)" 0
M1=$(md5sum /tmp/r3_map.json 2>/dev/null)
expect_out "a second restore --apply refuses rather than replace the reference map" 2 env R3_GO=$GO bash "$R3/run_ruby.sh" restore --apply
clean_refusal 'R3_MAP_FILE already exists'
is "reference map untouched by the refused second apply" "$(md5sum /tmp/r3_map.json 2>/dev/null)" "$M1"
map_keys() { python3 -c "import json,sys; print(sorted(json.load(open(sys.argv[1])).keys()))" "$1" 2>/dev/null; }
map_value() { python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$1" "$2" 2>/dev/null; }
A "DROP DATABASE IF EXISTS impl6_r3_partial_staged"; A "CREATE DATABASE impl6_r3_partial_staged TEMPLATE magi_archive_test"

echo; echo "--- id guards: an apply commits card by card, so no new id may ever reach the occupied range or a captured id"
echo '{"docs":[{"old_id":5,"name":"R3 Seq Doc One","type":"PlainText","content":"x"}],"nav":[],"accounts":[]}' > /tmp/r3_seq1.json
echo '{"docs":[{"old_id":40000,"name":"R3 Seq Doc Two","type":"PlainText","content":"x"}],"nav":[],"accounts":[]}' > /tmp/r3_seq2.json
rm -f /tmp/r3_map_seq1.json /tmp/r3_map_seq2.json
P "SELECT setval('cards_id_seq', 10980)" > /dev/null
expect_out "with the sequence just below the occupied range, the new card lands above it" 0 env R3_GO=$GO R3_STAGED_DB=impl6_r3_partial_staged R3_PRESERVE_FILE=/tmp/r3_seq1.json R3_MAP_FILE=/tmp/r3_map_seq1.json bash "$R3/run_ruby.sh" restore --apply
SEQ1_ID=$(map_value /tmp/r3_map_seq1.json 5)
is "the new id is above the occupied range" "$([ "${SEQ1_ID:-0}" -gt 11013 ] && echo yes || echo "no: ${SEQ1_ID:-none}")" yes
P "SELECT setval('cards_id_seq', 39999)" > /dev/null
expect_out "with the sequence's next id equal to the captured id, the new card takes a different one" 0 env R3_GO=$GO R3_STAGED_DB=impl6_r3_partial_staged R3_PRESERVE_FILE=/tmp/r3_seq2.json R3_MAP_FILE=/tmp/r3_map_seq2.json bash "$R3/run_ruby.sh" restore --apply
SEQ2_ID=$(map_value /tmp/r3_map_seq2.json 40000)
is "the new id is above the captured id" "$([ "${SEQ2_ID:-0}" -gt 40000 ] && echo yes || echo "no: ${SEQ2_ID:-none}")" yes
is "nothing took the captured id" "$(P "SELECT count(*) FROM cards WHERE id=40000")" 0

echo; echo "--- an apply that stops partway keeps a whole map of what it made"
echo '{"docs":[{"old_id":900011,"name":"R3 Bad Number","type":"Number","content":"not a number"}],"nav":[],"accounts":[]}' > /tmp/r3_first_bad.json
cat > /tmp/r3_second_bad.json <<'JSON'
{"docs":[{"old_id":900001,"name":"R3 Partial One","type":"PlainText","content":"x"},
         {"old_id":900002,"name":"R3 Partial One+Bad Number","type":"Number","content":"not a number"}],"nav":[],"accounts":[]}
JSON
rm -f /tmp/r3_map_first.json /tmp/r3_map_second.json /tmp/r3_map_partial.json
expect_out "an apply whose first card fails validation stops, with the map already there" 1 env R3_GO=$GO R3_STAGED_DB=impl6_r3_partial_staged R3_PRESERVE_FILE=/tmp/r3_first_bad.json R3_MAP_FILE=/tmp/r3_map_first.json bash "$R3/run_ruby.sh" restore --apply
has '^RESTORE stopped: 0 cards committed and mapped \(ActiveRecord::RecordInvalid\)'
lacks '^reference map written'
is "the map is empty" "$(map_keys /tmp/r3_map_first.json)" "[]"
is "the map file mode" "$(stat -c %a /tmp/r3_map_first.json 2>/dev/null)" 600
expect_out "an apply whose second card fails validation stops, with the first card mapped" 1 env R3_GO=$GO R3_STAGED_DB=impl6_r3_partial_staged R3_PRESERVE_FILE=/tmp/r3_second_bad.json R3_MAP_FILE=/tmp/r3_map_second.json bash "$R3/run_ruby.sh" restore --apply
has '^RESTORE stopped: 1 cards committed and mapped \(ActiveRecord::RecordInvalid\)'
lacks '^RESTORE created='
lacks '^reference map written'
is "the first card landed" "$(P "SELECT count(*) FROM cards WHERE name='R3 Partial One'")" 1
is "the map holds exactly the card that landed" "$(map_keys /tmp/r3_map_second.json)" "['900001']"
is "the partial map file mode" "$(stat -c %a /tmp/r3_map_second.json 2>/dev/null)" 600

echo; echo "--- committed but unmapped: an integrate-phase error after a card's commit must still leave that card in the map"
expect_out "an injected integrate failure stops the run, with every committed card mapped" 1 env DATABASE_URL=postgresql://magi@pg/impl6_r3_partial_staged R3_PRESERVE_STEP=restore R3_RESTORE_APPLY=1 R3_MAP_FILE=/tmp/r3_map_partial.json R3_INJECT_SCRIPT="$R3/dev_preservation.rb" bash -c 'cd "$1" && bundle _2.7.2_ exec decko runner "$2"' _ "$APP" "$L/e_r3_integrate_failure.rb"
has 'injected integrate failure'
has '^mail delivery during the integrate phase: false$'
has '^RESTORE stopped: 2 cards committed and mapped \(RuntimeError\)'
lacks '^reference map written'
lacks 'fixture-user@example'
is "the map file mode" "$(stat -c %a /tmp/r3_map_partial.json 2>/dev/null)" 600
is "map entries" "$(python3 -c "import json; print(len(json.load(open('/tmp/r3_map_partial.json'))))" 2>/dev/null)" 2
PARTIAL_IDS=$(python3 -c "import json; print(','.join(str(v) for v in json.load(open('/tmp/r3_map_partial.json')).values()))" 2>/dev/null)
is "mapped cards that are really in the database" "$(P "SELECT count(*) FROM cards WHERE id IN (${PARTIAL_IDS:-0})")" 2
is "the failing card's commit is durable and it is in the map" "$(P "SELECT count(*) FROM cards WHERE db_content='fixture doc' AND id IN (${PARTIAL_IDS:-0})")" 1
is "nothing after the failure was created" "$(P "SELECT count(*) FROM cards WHERE name='R3 Fixture User' OR db_content='fixture child'")" 0
A "DROP DATABASE impl6_r3_partial_staged"
is "restored simple cards" "$(Q "SELECT count(*) FROM cards WHERE name IN ('R3 Fixture Nav','R3 Fixture User')")" 2
is "restored doc child" "$(Q "SELECT count(*) FROM cards WHERE db_content='fixture child'")" 1
TYPE_OF="SELECT t.codename FROM cards c JOIN cards t ON t.id=c.type_id WHERE c.db_content"
is "the source doc has a type to compare" "$([ -n "$(C "$TYPE_OF='fixture doc'")" ] && echo yes || echo no)" yes
is "restored doc keeps the source doc's type" "$(Q "$TYPE_OF='fixture doc'")" "$(C "$TYPE_OF='fixture doc'")"
is "restored doc child keeps the source child's type" "$(Q "$TYPE_OF='fixture child'")" "$(C "$TYPE_OF='fixture child'")"
[ ! -e /tmp/r3_map.json.tmp ] && echo "PASS no temporary map file left" || { FAILS=$((FAILS+1)); echo "TEST FAIL temporary map file left"; }
is "recreated account has a password value" "$(Q "SELECT count(*) $ACCOUNT_PART AND r.codename='password' AND coalesce(c.db_content,'')<>''")" 1
SOURCE_MD5=$(C "SELECT md5(c.db_content) $ACCOUNT_PART AND r.codename='password'")
FRESH_MD5=$(Q "SELECT md5(c.db_content) $ACCOUNT_PART AND r.codename='password'")
if [ -n "$SOURCE_MD5" ] && [ -n "$FRESH_MD5" ] && [ "$SOURCE_MD5" != "$FRESH_MD5" ]; then echo "PASS recreated account's stored password differs from the source account's (compared, not printed)"; else FAILS=$((FAILS+1)); echo "TEST FAIL recreated account's stored password matches the source account's, or one is missing"; fi
is "recreated account's email" "$(Q "SELECT count(*) $ACCOUNT_PART AND r.codename='email' AND c.db_content='fixture-user@example.invalid'")" 1
is "recreated account's status" "$(Q "SELECT count(*) $ACCOUNT_PART AND r.codename='status' AND c.db_content='active'")" 1
FRESH_USER=$(Q "SELECT id FROM cards WHERE name='R3 Fixture User'")
is "recreated user is back in its role" "$(Q "SELECT count(*) FROM cards m JOIN cards l ON l.id=m.left_id JOIN cards r ON r.id=m.right_id WHERE l.name='Shark' AND r.codename='members' AND (m.db_content LIKE '%R3 Fixture User%' OR m.db_content ~ ('~' || '$FRESH_USER' || '([^0-9]|\$)'))")" 1
expect "restore on a database not named *_staged refuses" 2 env R3_GO=$GO R3_STAGED_DB=magi_probe_notstaged bash "$R3/run_ruby.sh" restore --apply
echo; echo "--- the Ruby guards alone, with the shell guard bypassed"
expect_out "Ruby guard: restore refuses a database not named *_staged" 2 env DATABASE_URL=postgresql://magi@pg/magi_probe_notstaged R3_PRESERVE_STEP=restore R3_RESTORE_APPLY=1 bash -c 'cd "$1" && bundle _2.7.2_ exec decko runner "$2"' _ "$APP" "$R3/dev_preservation.rb"
clean_refusal 'restore runs only on a database named'
expect_out "Ruby guard: capture refuses a staged copy" 2 env DATABASE_URL=postgresql://magi@pg/impl6_r3_staged R3_PRESERVE_STEP=capture bash -c 'cd "$1" && bundle _2.7.2_ exec decko runner "$2"' _ "$APP" "$R3/dev_preservation.rb"
clean_refusal 'capture reads the current dev database'
expect_out "Ruby guard: restore refuses while the mirror gate is on" 2 env DATABASE_URL=postgresql://magi@pg/impl6_r3_staged R3_PRESERVE_STEP=restore R3_RESTORE_APPLY=1 ATOMSPACE_MIRRORING_ENABLED=true bash -c 'cd "$1" && bundle _2.7.2_ exec decko runner "$2"' _ "$APP" "$R3/dev_preservation.rb"
clean_refusal 'the mirror gate is set'

echo; echo "################ ACCESS PROBES"
echo '{"excluded_ids":[999991,999992],"attachment_card_ids":[111]}' > /tmp/r3_m_ok.json
export R3_FILES_DIR=/tmp/r3att/store R3_PROBE_SAMPLE=40
rm -rf /tmp/r3att/store/111
echo '{"attachment_card_ids":[]}' > /tmp/r3_m_nokey.json
echo '{"excluded_ids":[1,"2 OR 1=1"],"attachment_card_ids":[]}' > /tmp/r3_m_badid.json
echo '[1,2]' > /tmp/r3_map_array.json
echo '{"1":"abc"}' > /tmp/r3_map_badid.json
expect_out "probes with a reference map that does not exist refuse" 2 env R3_MANIFEST=/tmp/r3_m_ok.json R3_MAP_FILE=/tmp/r3_no_such_map.json bash "$R3/run_ruby.sh" probes
clean_refusal 'R3_MAP_FILE'
expect_out "probes with a directory as the reference map refuse" 2 env R3_MANIFEST=/tmp/r3_m_ok.json R3_MAP_FILE=/tmp bash "$R3/run_ruby.sh" probes
clean_refusal 'R3_MAP_FILE'
expect_out "probes with a malformed reference map refuse" 2 env R3_MANIFEST=/tmp/r3_m_ok.json R3_MAP_FILE=/tmp/r3_bad.json bash "$R3/run_ruby.sh" probes
clean_refusal 'R3_MAP_FILE'
lacks 'not json'
expect_out "probes with a reference map of the wrong shape refuse" 2 env R3_MANIFEST=/tmp/r3_m_ok.json R3_MAP_FILE=/tmp/r3_map_array.json bash "$R3/run_ruby.sh" probes
clean_refusal 'R3_MAP_FILE'
expect_out "probes with a non-integer id in the reference map refuse" 2 env R3_MANIFEST=/tmp/r3_m_ok.json R3_MAP_FILE=/tmp/r3_map_badid.json bash "$R3/run_ruby.sh" probes
clean_refusal 'R3_MAP_FILE'
expect_out "probes with R3_MANIFEST unset refuse" 2 env -u R3_MANIFEST bash "$R3/run_ruby.sh" probes
clean_refusal 'R3_MANIFEST'
expect_out "probes with a manifest that does not exist refuse" 2 env R3_MANIFEST=/tmp/r3_no_such_manifest.json bash "$R3/run_ruby.sh" probes
clean_refusal 'R3_MANIFEST'
expect_out "probes with a malformed manifest refuse" 2 env R3_MANIFEST=/tmp/r3_bad.json bash "$R3/run_ruby.sh" probes
clean_refusal 'R3_MANIFEST'
lacks 'not json'
expect_out "probes with a manifest missing a list refuse" 2 env R3_MANIFEST=/tmp/r3_m_nokey.json bash "$R3/run_ruby.sh" probes
clean_refusal 'R3_MANIFEST'
expect_out "probes with a non-integer id in the manifest refuse" 2 env R3_MANIFEST=/tmp/r3_m_badid.json bash "$R3/run_ruby.sh" probes
clean_refusal 'R3_MANIFEST'
expect_out "probes pass on the sanitized copy" 0 env R3_MANIFEST=/tmp/r3_m_ok.json bash "$R3/run_ruby.sh" probes
has '^PROBES FAILURES=0$'
lacks '^FAIL '
lacks 'from /'
for line in 'no excluded card row remains' 'no excluded attachment remains in the store' 'no secret value remains outside the recreated accounts' \
            'no unsanitized account email remains outside the recreated accounts' 'no users row holds a credential' \
            'a sample of public cards exists' 'Anonymous can read every sampled public card' 'Anonymous cannot read any sampled restricted card' \
            'a principal named by the rule can read each restricted card' 'preserved dev account 1 exists as a User'; do
  has "^PASS $line"
done
RETAINED=$(Q "SELECT min(id) FROM cards WHERE name='R3 Fixture Nav'")
echo "{\"excluded_ids\":[$RETAINED],\"attachment_card_ids\":[333]}" > /tmp/r3_m_bad.json
expect_out "probes FAIL when an excluded card and blob are still present" 1 env R3_MANIFEST=/tmp/r3_m_bad.json bash "$R3/run_ruby.sh" probes
has '^FAIL no excluded card row remains'
has '^FAIL no excluded attachment remains in the store'
has '^PROBES FAILURES=[1-9]'
lacks 'from /'
expect "probes on a database not named *_staged refuse" 2 env R3_STAGED_DB=magi_probe_notstaged R3_MANIFEST=/tmp/r3_m_ok.json bash "$R3/run_ruby.sh" probes
expect_out "Ruby guard: probes refuse a database not named *_staged" 2 env DATABASE_URL=postgresql://magi@pg/magi_probe_notstaged R3_MANIFEST=/tmp/r3_m_ok.json bash -c 'cd "$1" && bundle _2.7.2_ exec decko runner "$2"' _ "$APP" "$R3/access_probes.rb"
clean_refusal 'probes run only on a database named'

echo; echo "--- negative control: the sanitization probes must catch made-up credentials put back on a seed account"
SEED_PART="FROM cards c JOIN cards r ON r.id=c.right_id JOIN cards l ON l.id=c.left_id JOIN cards u ON u.id=l.left_id WHERE u.name<>'R3 Fixture User'"
Q "UPDATE cards SET db_content='made-up-value' WHERE id=(SELECT min(c.id) $SEED_PART AND r.codename='password')"
Q "UPDATE cards SET db_content='made-up@example.invalid' WHERE id=(SELECT min(c.id) $SEED_PART AND r.codename='email')"
Q "UPDATE users SET crypted_password='made-up-hash'"
expect_out "probes FAIL on leftover credentials" 1 env R3_MANIFEST=/tmp/r3_m_ok.json bash "$R3/run_ruby.sh" probes
has '^FAIL no secret value remains outside the recreated accounts'
has '^FAIL no unsanitized account email remains outside the recreated accounts'
has '^FAIL no users row holds a credential'
lacks 'from /'
lacks 'made-up'

echo; echo "--- cleanup: disposable databases and files"
A "DROP DATABASE impl6_r3_staged"; A "DROP DATABASE impl6_r3_capture"; A "DROP DATABASE magi_probe_notstaged"
rm -rf /tmp/r3att /tmp/r3_preserve.json /tmp/r3_map.json /tmp/r3_fake.env /tmp/r3_fake2.env /tmp/r3_m_ok.json /tmp/r3_m_bad.json \
       /tmp/r3_bad.json /tmp/r3_wrong_shape.json /tmp/r3_m_nokey.json /tmp/r3_m_badid.json /tmp/r3_map_array.json /tmp/r3_map_badid.json "$LAST" \
       /tmp/r3_seq1.json /tmp/r3_seq2.json /tmp/r3_map_seq1.json /tmp/r3_map_seq2.json /tmp/r3_first_bad.json /tmp/r3_second_bad.json \
       /tmp/r3_map_first.json /tmp/r3_map_second.json /tmp/r3_map_partial.json
echo "E_TEST_FAILURES=$FAILS"
[ "$FAILS" = 0 ]
