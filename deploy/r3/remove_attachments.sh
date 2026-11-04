#!/bin/bash
# R3 attachment removal: moves the excluded cards' blobs out of the shared store into a mode-700 holding directory. It
# deletes nothing, so it can be undone. Prints card ids, counts and bytes, never a file name.
#
# Rollback: run rollback.sh in the holding directory. It moves every item back to where it came from.
#
# usage: R3_MANIFEST=<strict manifest json> R3_FILES_DIR=<store> R3_PUBLIC_FILES_DIR=<public/files> R3_HOLDING=<new dir> \
#        remove_attachments.sh [--dry-run|--apply]
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
r3_parse_mode "$@"
r3_load_db_env
r3_assert_target

[ -n "${R3_MANIFEST:-}" ] || r3_die "R3_MANIFEST is not set"
: "${R3_FILES_DIR:?set R3_FILES_DIR}"
[ -r "$R3_MANIFEST" ] || r3_die "cannot read the manifest"
[ -d "$R3_FILES_DIR" ] || r3_die "no such store"
STORE=$(readlink -f "$R3_FILES_DIR")
PUBLIC=${R3_PUBLIC_FILES_DIR:-}
[ -z "$PUBLIC" ] || PUBLIC=$(readlink -f "$PUBLIC")

# Read in a command substitution, not a process substitution: its exit status is what proves the whole list was valid.
ID_LIST=$(python3 -c '
import json, sys
try:
    ids = json.load(open(sys.argv[1]))["attachment_card_ids"]
except (ValueError, KeyError, TypeError):
    sys.exit("the manifest is not a strict manifest")
if not isinstance(ids, list):
    sys.exit("the manifest is not a strict manifest")
for i in ids:
    if not isinstance(i, int) or isinstance(i, bool) or i <= 0:
        sys.exit("manifest holds a non-integer attachment id")
    print(i)' "$R3_MANIFEST") || r3_die "the manifest is malformed"
IDS=()
[ -z "$ID_LIST" ] || mapfile -t IDS <<<"$ID_LIST"
echo "attachment cards in the manifest: ${#IDS[@]}"

TOTAL_DIRS=0; TOTAL_FILES=0; TOTAL_BYTES=0; PRESENT_IDS=()
for id in "${IDS[@]}"; do
  for root in "$STORE" "$PUBLIC"; do
    [ -n "$root" ] || continue
    for d in "$root/$id" "$root/~$id"; do
      if [ -d "$d" ]; then
        TOTAL_DIRS=$((TOTAL_DIRS + 1))
        TOTAL_FILES=$((TOTAL_FILES + $(find "$d" -type f | wc -l)))
        TOTAL_BYTES=$((TOTAL_BYTES + $(du -sb "$d" | cut -f1)))
        PRESENT_IDS+=("$d")
      fi
    done
  done
done
echo "found: directories=$TOTAL_DIRS files=$TOTAL_FILES bytes=$TOTAL_BYTES"

if [ "$MODE" != apply ]; then
  echo "dry run: nothing was moved"
  exit 0
fi

: "${R3_HOLDING:?set R3_HOLDING}"
[ ! -e "$R3_HOLDING" ] || r3_die "the holding directory already exists; inspect it by hand"
( umask 077; mkdir -p "$R3_HOLDING" ) || r3_die "cannot create the holding directory"
ROLLBACK="$R3_HOLDING/rollback.sh"
printf '#!/bin/bash\nset -eu\n' > "$ROLLBACK"
n=0
for d in "${PRESENT_IDS[@]}"; do
  n=$((n + 1))
  mv "$d" "$R3_HOLDING/$n" || { echo "MOVE FAILED at item $n; run $ROLLBACK to undo the earlier moves" >&2; exit 1; }
  printf 'mv %q %q\n' "$R3_HOLDING/$n" "$d" >> "$ROLLBACK"
done
chmod 700 "$ROLLBACK"
LEFT=0
for id in "${IDS[@]}"; do
  for root in "$STORE" "$PUBLIC"; do
    [ -n "$root" ] || continue
    [ -e "$root/$id" ] && LEFT=$((LEFT + 1))
    [ -e "$root/~$id" ] && LEFT=$((LEFT + 1))
  done
done
echo "moved: $n; left in the store for these ids: $LEFT (must be 0)"
[ "$LEFT" = 0 ] || exit 1
echo "attachments held; rollback script written (path not printed)"
