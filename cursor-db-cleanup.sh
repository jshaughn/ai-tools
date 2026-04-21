#!/usr/bin/env bash
#
# Cleans up Cursor's global state.vscdb by removing old conversation data.
# Removes all chat history, checkpoints, and associated data created before
# a given cutoff date, preserving everything from that date onward.
#
# Options:
#   --cutoff YYYY-MM-DD  Delete conversations before this date (default: 90 days ago)
#   --execute            Actually perform the cleanup (without this, it's a dry-run)
#   --aggressive         Also delete ALL agentKv:blob entries (cached agent subprocess
#                        transcripts) and composer.content entries. These are keyed by
#                        content hash and can't be filtered by date, so --aggressive
#                        deletes all of them including ones from recent conversations.
#                        You lose the ability to resume old agent subprocesses, but
#                        your visible chat history is not affected.
#
# Examples:
#   ./cursor-db-cleanup.sh                          # dry-run, default cutoff 90 days ago
#   ./cursor-db-cleanup.sh --cutoff 2026-01-01      # dry-run, keep from Jan 1 2026 onward
#   ./cursor-db-cleanup.sh --cutoff 2026-03-01 --execute
#   ./cursor-db-cleanup.sh --aggressive --execute
#
# IMPORTANT: Close Cursor completely before running with --execute.

set -euo pipefail

DB_PATH="$HOME/.config/Cursor/User/globalStorage/state.vscdb"
BACKUP_PATH="${DB_PATH}.backup-$(date +%Y%m%d-%H%M%S)"

EXECUTE=false
AGGRESSIVE=false
CUTOFF_DATE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --execute) EXECUTE=true; shift ;;
        --aggressive) AGGRESSIVE=true; shift ;;
        --cutoff)
            if [[ -z "${2:-}" ]]; then
                echo "ERROR: --cutoff requires a date argument (e.g. 2026-01-01)"
                exit 1
            fi
            CUTOFF_DATE="$2"
            shift 2
            ;;
        --help|-h)
            head -21 "$0" | tail -19
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--cutoff YYYY-MM-DD] [--execute] [--aggressive]"
            exit 1
            ;;
    esac
done

# Convert cutoff date to epoch milliseconds, defaulting to 30 days ago
if [[ -n "$CUTOFF_DATE" ]]; then
    CUTOFF_MS=$(python3 -c "
import datetime, sys
try:
    dt = datetime.datetime.strptime('$CUTOFF_DATE', '%Y-%m-%d').replace(tzinfo=datetime.timezone.utc)
    print(int(dt.timestamp() * 1000))
except ValueError:
    print('ERROR: Invalid date format. Use YYYY-MM-DD (e.g. 2026-01-01)', file=sys.stderr)
    sys.exit(1)
")
    CUTOFF_DISPLAY="$CUTOFF_DATE"
else
    CUTOFF_MS=$(python3 -c "
import datetime
dt = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=90)
dt = dt.replace(hour=0, minute=0, second=0, microsecond=0)
print(int(dt.timestamp() * 1000))
")
    CUTOFF_DISPLAY=$(python3 -c "
import datetime
dt = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=90)
print(dt.strftime('%Y-%m-%d'))
")
fi

if [[ ! -f "$DB_PATH" ]]; then
    echo "ERROR: Database not found at $DB_PATH"
    exit 1
fi

if pgrep -f '[C]ursor' > /dev/null 2>&1; then
    echo "WARNING: Cursor appears to be running."
    if $EXECUTE; then
        echo "ERROR: Close Cursor before running with --execute to avoid corruption."
        exit 1
    fi
fi

echo "Database: $DB_PATH"
echo "File size: $(du -h "$DB_PATH" | cut -f1)"
echo "Cutoff: everything created before $CUTOFF_DISPLAY will be removed"
echo "Mode: $($EXECUTE && echo 'EXECUTE' || echo 'DRY-RUN')"
echo "Aggressive: $AGGRESSIVE"
echo ""

# Phase 1: Extract 2025 composerIds via Python (JSON parsing)
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

sqlite3 "$DB_PATH" "SELECT value FROM ItemTable WHERE key = 'composer.composerHeaders';" > "$TMPDIR/headers.json"

python3 << PYEOF > "$TMPDIR/cleanup_plan.sql"
import json, sys

with open("$TMPDIR/headers.json") as f:
    content = f.read().strip()
    if not content:
        print("-- No composer headers found, nothing to do", file=sys.stderr)
        sys.exit(1)
    data = json.loads(content)

composers = data.get("allComposers", [])
cutoff = $CUTOFF_MS

ids_to_delete = set()
ids_to_keep = set()
for c in composers:
    cid = c.get("composerId", "")
    if c.get("createdAt", 0) < cutoff:
        ids_to_delete.add(cid)
    else:
        ids_to_keep.add(cid)

print(f"-- Conversations to delete: {len(ids_to_delete)} (before $CUTOFF_DISPLAY)", file=sys.stderr)
print(f"-- Conversations to keep:   {len(ids_to_keep)} (on or after $CUTOFF_DISPLAY)", file=sys.stderr)

# Build the updated headers JSON (only 2026 conversations)
kept = [c for c in composers if c.get("composerId", "") in ids_to_keep]
new_headers = json.dumps({"allComposers": kept})

# Escape single quotes for SQL
new_headers_escaped = new_headers.replace("'", "''")

# Write the SQL script
print("BEGIN TRANSACTION;")
print()

# Delete conversation-associated rows for 2025 composerIds
prefixes = [
    "bubbleId:",
    "messageRequestContext:",
    "composerData:",
    "checkpointId:",
    "inlineDiff:",
    "patch-graph:",
]

for cid in sorted(ids_to_delete):
    for prefix in prefixes:
        print(f"DELETE FROM cursorDiskKV WHERE key LIKE '{prefix}{cid}:%';")
    print(f"DELETE FROM cursorDiskKV WHERE key = 'composerData:{cid}';")

print()
print("-- Delete orphaned entries (composerIds not in any header)")

# Build the orphan cleanup: delete entries whose composerId prefix
# is neither in the keep set nor the delete set (already gone from headers).
# We match on prefix patterns for the known key types.
for prefix in prefixes:
    conditions = []
    for cid in sorted(ids_to_keep):
        conditions.append(f"key NOT LIKE '{prefix}{cid}:%'")
    # Rather than a massive NOT LIKE chain, delete everything for this prefix
    # then re-think... actually, the efficient way is to keep the 2026 IDs.
    # With 271 keep IDs, a NOT IN approach via substr is cleaner.
    pass

# Simpler orphan approach: delete all rows for these prefixes
# where the composerId is not in the keep set.
# We'll generate this as a Python-driven approach.
keep_list_sql = ",".join(f"'{cid}'" for cid in sorted(ids_to_keep))
for prefix in prefixes:
    key_prefix = prefix
    # composerId sits right after the prefix, 36 chars (UUID length)
    # For task-* IDs, they're longer, so use substr up to first ':'
    print(f"""DELETE FROM cursorDiskKV
  WHERE key LIKE '{key_prefix}%'
  AND substr(key, {len(key_prefix)+1}, 36) NOT IN ({keep_list_sql});""")

print()

# Update the composer headers to only include 2026 conversations
print(f"UPDATE ItemTable SET value = '{new_headers_escaped}' WHERE key = 'composer.composerHeaders';")
print()

aggressive = "$AGGRESSIVE" == "true"
if aggressive:
    print("-- AGGRESSIVE: Delete all agentKv:blob entries")
    print("DELETE FROM cursorDiskKV WHERE key LIKE 'agentKv:blob:%';")
    print()
    print("-- AGGRESSIVE: Delete all composer.content entries")
    print("DELETE FROM cursorDiskKV WHERE key LIKE 'composer.content.%';")
    print()

print("COMMIT;")
print("VACUUM;")
PYEOF

# Phase 2: Show the plan / estimate
echo ""
echo "=== CLEANUP PLAN ==="
echo ""

python3 << PYEOF
import sqlite3, json

db_path = "$DB_PATH"
cutoff = $CUTOFF_MS
aggressive = "$AGGRESSIVE" == "true"

with open("$TMPDIR/headers.json") as f:
    data = json.loads(f.read().strip())

composers = data.get("allComposers", [])
ids_before = set()
ids_after = set()
for c in composers:
    cid = c.get("composerId", "")
    if c.get("createdAt", 0) < cutoff:
        ids_before.add(cid)
    else:
        ids_after.add(cid)

conn = sqlite3.connect(db_path)
cur = conn.cursor()

prefixes = ["bubbleId:", "messageRequestContext:", "composerData:", "checkpointId:", "inlineDiff:", "patch-graph:"]

delete_rows = 0
delete_bytes = 0
orphan_rows = 0
orphan_bytes = 0

print(f"{'Category':<35s} {'Rows':>8s} {'Size (MB)':>10s}")
print("-" * 55)

for prefix in prefixes:
    cur.execute("SELECT key, length(value) FROM cursorDiskKV WHERE key LIKE ?", (prefix + "%",))
    rows = cur.fetchall()
    match_r = 0
    match_b = 0
    orph_r = 0
    orph_b = 0
    for key, vlen in rows:
        vlen = vlen or 0
        rest = key[len(prefix):]
        cid = rest.split(":")[0]
        if cid in ids_before:
            match_r += 1
            match_b += vlen
        elif cid not in ids_after:
            orph_r += 1
            orph_b += vlen
    delete_rows += match_r
    delete_bytes += match_b
    orphan_rows += orph_r
    orphan_bytes += orph_b
    total_r = match_r + orph_r
    total_b = match_b + orph_b
    if total_r > 0:
        print(f"  {prefix:<33s} {total_r:>8,} {total_b/1048576:>10.1f}")

print("-" * 55)
safe_rows = delete_rows + orphan_rows
safe_bytes = delete_bytes + orphan_bytes
print(f"  {'Subtotal (safe):':<33s} {safe_rows:>8,} {safe_bytes/1048576:>10.1f}")

agg_bytes = 0
if aggressive:
    cur.execute("SELECT COUNT(*), COALESCE(SUM(length(value)),0) FROM cursorDiskKV WHERE key LIKE 'agentKv:blob:%'")
    br, bb = cur.fetchone()
    print(f"  {'agentKv:blob (aggressive):':<33s} {br:>8,} {bb/1048576:>10.1f}")
    agg_bytes += bb

    cur.execute("SELECT COUNT(*), COALESCE(SUM(length(value)),0) FROM cursorDiskKV WHERE key LIKE 'composer.content.%'")
    cr, cb = cur.fetchone()
    print(f"  {'composer.content (aggressive):':<33s} {cr:>8,} {cb/1048576:>10.1f}")
    agg_bytes += cb
    print("-" * 55)

total_reclaim = safe_bytes + agg_bytes
import os
file_size = os.path.getsize(db_path)
print(f"\n  Current DB size:                {file_size/1048576:>10.1f} MB")
print(f"  Data to remove:                 {total_reclaim/1048576:>10.1f} MB")
print(f"  Estimated size after cleanup:   {(file_size - total_reclaim)/1048576:>10.1f} MB")
print(f"\n  Conversations kept (>= $CUTOFF_DISPLAY):  {len(ids_after):>10,}")
print(f"  Conversations removed (< $CUTOFF_DISPLAY): {len(ids_before):>10,}")
print(f"  Orphaned entries removed:              {orphan_rows:>10,}")

conn.close()
PYEOF

echo ""

if $EXECUTE; then
    echo "=== EXECUTING CLEANUP ==="
    echo ""
    echo "Creating backup at: $BACKUP_PATH"
    cp "$DB_PATH" "$BACKUP_PATH"
    echo "Backup size: $(du -h "$BACKUP_PATH" | cut -f1)"
    echo ""
    echo "Running SQL cleanup (this may take a few minutes for VACUUM)..."
    time sqlite3 "$DB_PATH" < "$TMPDIR/cleanup_plan.sql"
    echo ""
    echo "Done!"
    echo "New DB size: $(du -h "$DB_PATH" | cut -f1)"
    echo "Backup at:   $BACKUP_PATH"
    echo ""
    echo "You can delete the backup once you've verified Cursor works:"
    echo "  rm '$BACKUP_PATH'"
else
    echo "This is a DRY RUN. To actually clean up, run:"
    echo "  $0 --execute"
    if ! $AGGRESSIVE; then
        echo ""
        echo "To also remove agentKv blobs and composer.content (more space, but"
        echo "may affect ability to resume old 2026 agent conversations):"
        echo "  $0 --aggressive --execute"
    fi
fi
