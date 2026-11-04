#!/bin/bash
# Runs dev_preservation.rb or access_probes.rb through decko runner, with the same guards as the shell scripts.
#
#   run_ruby.sh capture  [--dry-run|--apply]    read-only, on the CURRENT dev database; --apply needs R3_GO, writes the file
#   run_ruby.sh restore  [--dry-run|--apply]    on the staged database; --apply needs R3_GO
#   run_ruby.sh probes                          read-only, on the staged database
#
# Env: R3_APP_DIR, plus each script's own settings.
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
STEP=${1:-}; shift || true
case "$STEP" in capture|restore|probes) ;; *) r3_die "the first argument must be capture, restore or probes";; esac
r3_parse_mode "$@"
[ "$STEP" != probes ] || [ "$MODE" = dry-run ] || r3_die "probes have no --apply"
r3_load_db_env
r3_assert_target
: "${R3_APP_DIR:?set R3_APP_DIR}"
cd "$R3_APP_DIR" || r3_die "no such app directory"

# The refresh requires a dormant mirror. These scripts must not write outbox rows, so the gate is forced off here.
unset ATOMSPACE_MIRRORING_ENABLED
export RAILS_ENV="${RAILS_ENV:-production}"
# G-CACHE. Cardio.database is read from database.yml, so the DATABASE_URL set below moves the
# connection but NOT the Rails cache namespace: without this these staged-DB scripts would read and
# write the LIVE deck's shared cache. Verified in card-1.110.0 (lib/cardio.rb:44,
# lib/card/cache/shared_class.rb:15, lib/card/cache/class_methods.rb:106).
export NO_RAILS_CACHE=true

case "$STEP" in
  capture)
    export R3_PRESERVE_STEP=capture
    SCRIPT="$HERE/dev_preservation.rb"
    if [ "$MODE" = apply ]; then export R3_CAPTURE_WRITE=1; else unset R3_CAPTURE_WRITE; fi
    [ "${R3_LOCAL_TEST:-}" = 1 ] && export DATABASE_URL="postgresql://$DB_USERNAME@$DB_HOST/${R3_CAPTURE_DB:?set R3_CAPTURE_DB}"
    ;;
  restore)
    export R3_PRESERVE_STEP=restore DATABASE_URL="postgresql://$DB_USERNAME@$DB_HOST/$STAGED_DB"
    SCRIPT="$HERE/dev_preservation.rb"
    if [ "$MODE" = apply ]; then export R3_RESTORE_APPLY=1; else unset R3_RESTORE_APPLY; fi
    ;;
  probes)
    export DATABASE_URL="postgresql://$DB_USERNAME@$DB_HOST/$STAGED_DB"
    SCRIPT="$HERE/access_probes.rb"
    ;;
esac
export DATABASE_PASSWORD
# stderr can quote card data in an exception, so outside local tests only the scripts' own REFUSED lines get through.
if [ "${R3_LOCAL_TEST:-}" = 1 ]; then
  bundle _2.7.2_ exec decko runner "$SCRIPT"
  RC=$?
else
  ERR=$(mktemp)
  bundle exec decko runner "$SCRIPT" 2>"$ERR"
  RC=$?
  grep -E '^REFUSED' "$ERR" >&2
  [ "$RC" = 0 ] || [ "$RC" = 2 ] || echo "${STEP} failed; error text withheld because it can quote card data" >&2
  rm -f "$ERR"
fi
echo "${STEP}_exit=$RC"
exit "$RC"
