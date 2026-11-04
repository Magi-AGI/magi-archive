#!/bin/bash
# Shared guards for the R3 scripts. Each script is a dry run by default. Nothing destructive happens unless
# --apply is given AND R3_GO carries the gate value, and everything works on a database named *_staged.
set -uo pipefail

R3_GATE_VALUE=replace-dev-db-with-strict-filtered-prod-copy
R3_DEV_INSTANCE=i-057ad2c339fe45765
R3_ENV_FILE=${R3_ENV_FILE:-/home/ubuntu/magi-archive/.env.production}

r3_die() { echo "REFUSED: $*" >&2; exit 2; }

# Loads DB_HOST, DB_USERNAME and DATABASE_PASSWORD by exact name, so nothing else from the env file enters this shell.
r3_load_db_env() {
  if [ "${R3_LOCAL_TEST:-}" != 1 ]; then
    [ -r "$R3_ENV_FILE" ] || r3_die "cannot read the app env file"
    eval "$(grep -E '^(export )?(DB_HOST|DB_USERNAME|DATABASE_PASSWORD)=' "$R3_ENV_FILE" | sed -E 's/^export //')"
  fi
  [ -n "${DB_HOST:-}" ] && [ -n "${DB_USERNAME:-}" ] && [ -n "${DATABASE_PASSWORD:-}" ] || r3_die "database settings are incomplete"
  export PGPASSWORD="$DATABASE_PASSWORD"
}

# Proves the target before anything else. Local test mode is honoured only against the disposable container's host.
r3_assert_target() {
  if [ "${R3_LOCAL_TEST:-}" = 1 ]; then
    [ "${DB_HOST:-}" = pg ] || r3_die "R3_LOCAL_TEST is only valid against the disposable local database"
    echo "target: LOCAL TEST, disposable database host"
  else
    local t i
    t=$(curl -sf -m 3 -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60') || r3_die "cannot reach instance metadata"
    i=$(curl -sf -m 3 -H "X-aws-ec2-metadata-token: $t" http://169.254.169.254/latest/meta-data/instance-id) || r3_die "cannot read the instance id"
    [ "$i" = "$R3_DEV_INSTANCE" ] || r3_die "this is not the dev instance"
    case "$DB_HOST" in *magi-archive-dev.*) ;; *) r3_die "DB_HOST is not the dev RDS";; esac
    echo "target: dev instance $i, dev RDS (host not printed)"
  fi
  STAGED_DB=${R3_STAGED_DB:-magi_archive_staged}
  case "$STAGED_DB" in
    *_staged) ;;
    *) r3_die "database '$STAGED_DB' is not a staged copy (the name must end in _staged)";;
  esac
  case "$STAGED_DB" in *[!a-z0-9_]*) r3_die "bad database name";; esac
  echo "staged database: $STAGED_DB"
}

# Sets MODE to dry-run or apply. --apply without the exact gate value is a refusal, not a dry run.
r3_parse_mode() {
  MODE=dry-run
  for arg in "$@"; do
    case "$arg" in
      --apply) MODE=apply ;;
      --dry-run) MODE=dry-run ;;
      *) r3_die "unknown argument $arg" ;;
    esac
  done
  if [ "$MODE" = apply ] && [ "${R3_GO:-}" != "$R3_GATE_VALUE" ]; then
    r3_die "--apply needs R3_GO; this is a fresh owner decision. Nothing was changed."
  fi
  echo "mode: $MODE"
}

r3_psql() { psql -h "$DB_HOST" -U "$DB_USERNAME" -d "$STAGED_DB" -v ON_ERROR_STOP=1 "$@"; }
