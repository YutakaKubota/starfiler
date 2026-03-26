#!/bin/zsh
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/network_sync_local_smoke.sh [--skip-build] [--keep-running] [--base-dir PATH]

Launches two Starfiler instances on the same Mac with separate config roots and sync roots,
then verifies basic server/client sync, selective sync, and the directory-conflict regression.

Options:
  --skip-build     Do not run build_and_install.sh before launching
  --keep-running   Leave both Starfiler processes running after verification
  --base-dir PATH  Use an existing directory instead of creating a fresh temp workspace
EOF
}

SKIP_BUILD=0
KEEP_RUNNING=0
BASE_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build)
      SKIP_BUILD=1
      ;;
    --keep-running)
      KEEP_RUNNING=1
      ;;
    --base-dir)
      shift
      BASE_DIR="${1:-}"
      if [[ -z "$BASE_DIR" ]]; then
        echo "--base-dir requires a path" >&2
        exit 1
      fi
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_BIN="/Applications/Starfiler.app/Contents/MacOS/Starfiler"

if [[ $SKIP_BUILD -eq 0 ]]; then
  "$REPO_ROOT/scripts/build_and_install.sh"
fi

if [[ ! -x "$APP_BIN" ]]; then
  echo "Starfiler app binary not found at $APP_BIN" >&2
  exit 1
fi

if [[ -n "$BASE_DIR" ]]; then
  WORK_DIR="$BASE_DIR"
  mkdir -p "$WORK_DIR"
else
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/starfiler-network-sync-local.XXXXXX")"
fi

SERVER_ROOT="$WORK_DIR/server-root"
CLIENT_ROOT="$WORK_DIR/client-root"
SERVER_CONFIG="$WORK_DIR/server-config"
CLIENT_CONFIG="$WORK_DIR/client-config"
SERVER_LOG="$WORK_DIR/server.log"
CLIENT_LOG="$WORK_DIR/client.log"
REPORT="$WORK_DIR/verification-report.txt"

mkdir -p "$SERVER_ROOT" "$CLIENT_ROOT" "$SERVER_CONFIG" "$CLIENT_CONFIG" "$SERVER_ROOT/docs" "$SERVER_ROOT/private"
DISCOVERY_SCOPE="local-smoke-$(uuidgen | tr '[:upper:]' '[:lower:]')"

cat > "$SERVER_CONFIG/NetworkSync.json" <<EOF
{
  "isEnabled": true,
  "mode": "server",
  "displayName": "Local Smoke Server",
  "discoveryScope": "$DISCOVERY_SCOPE",
  "rootPath": "$SERVER_ROOT",
  "includedPaths": [],
  "conflictPolicy": "keepBoth",
  "heartbeatIntervalSeconds": 5,
  "syncDebounceSeconds": 0.5,
  "peers": []
}
EOF

cat > "$CLIENT_CONFIG/NetworkSync.json" <<EOF
{
  "isEnabled": true,
  "mode": "client",
  "displayName": "Local Smoke Client",
  "discoveryScope": "$DISCOVERY_SCOPE",
  "rootPath": "$CLIENT_ROOT",
  "includedPaths": ["docs"],
  "conflictPolicy": "keepBoth",
  "heartbeatIntervalSeconds": 5,
  "syncDebounceSeconds": 0.5,
  "peers": []
}
EOF

print_report() {
  cat <<EOF > "$REPORT"
Starfiler Network Sync Local Smoke
Date: $(date '+%Y-%m-%d %H:%M:%S %z')
Workspace: $WORK_DIR
Discovery scope: $DISCOVERY_SCOPE
Server root: $SERVER_ROOT
Client root: $CLIENT_ROOT
Server config: $SERVER_CONFIG
Client config: $CLIENT_CONFIG
EOF
}

append_report() {
  print -r -- "$1" >> "$REPORT"
}

wait_for_path() {
  local path="$1"
  local timeout="${2:-20}"
  local elapsed=0
  while (( elapsed < timeout )); do
    if [[ -e "$path" ]]; then
      return 0
    fi
    /bin/sleep 1
    (( elapsed += 1 ))
  done
  return 1
}

wait_for_absence() {
  local path="$1"
  local timeout="${2:-20}"
  local elapsed=0
  while (( elapsed < timeout )); do
    if [[ ! -e "$path" ]]; then
      return 0
    fi
    /bin/sleep 1
    (( elapsed += 1 ))
  done
  return 1
}

restart_client() {
  if [[ -n "${CLIENT_PID:-}" ]] && kill -0 "$CLIENT_PID" 2>/dev/null; then
    kill "$CLIENT_PID" 2>/dev/null || true
    wait "$CLIENT_PID" 2>/dev/null || true
  fi
  "$APP_BIN" --uitest --disable-animations --config-root "$CLIENT_CONFIG" --sandbox-root "$CLIENT_ROOT" > "$CLIENT_LOG" 2>&1 &
  CLIENT_PID=$!
}

cleanup() {
  if [[ $KEEP_RUNNING -eq 1 ]]; then
    return
  fi
  if [[ -n "${CLIENT_PID:-}" ]] && kill -0 "$CLIENT_PID" 2>/dev/null; then
    kill "$CLIENT_PID" 2>/dev/null || true
    wait "$CLIENT_PID" 2>/dev/null || true
  fi
  if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

print_report

print "seed from server" > "$SERVER_ROOT/docs/initial.txt"
print "hidden on first pass" > "$SERVER_ROOT/private/hidden.txt"

"$APP_BIN" --uitest --disable-animations --config-root "$SERVER_CONFIG" --sandbox-root "$SERVER_ROOT" > "$SERVER_LOG" 2>&1 &
SERVER_PID=$!
restart_client

append_report ""
append_report "Checks:"

if wait_for_path "$CLIENT_ROOT/docs/initial.txt" 25; then
  append_report "PASS initial server -> client sync"
else
  append_report "FAIL initial server -> client sync"
  exit 1
fi

if wait_for_absence "$CLIENT_ROOT/private/hidden.txt" 5; then
  append_report "PASS excluded path stays local-absent before selection"
else
  append_report "FAIL excluded path unexpectedly synced before selection"
  exit 1
fi

print "from client" > "$CLIENT_ROOT/docs/from-client.txt"
if wait_for_path "$SERVER_ROOT/docs/from-client.txt" 25; then
  append_report "PASS client -> server upload"
else
  append_report "FAIL client -> server upload"
  exit 1
fi

print "server follow-up" > "$SERVER_ROOT/docs/from-server.txt"
if wait_for_path "$CLIENT_ROOT/docs/from-server.txt" 25; then
  append_report "PASS server -> client follow-up sync"
else
  append_report "FAIL server -> client follow-up sync"
  exit 1
fi

mkdir -p "$CLIENT_ROOT/docs/nested"
print "nested edit" > "$CLIENT_ROOT/docs/nested/local.txt"
if wait_for_path "$SERVER_ROOT/docs/nested/local.txt" 25; then
  append_report "PASS nested client folder upload"
else
  append_report "FAIL nested client folder upload"
  exit 1
fi

mkdir -p "$CLIENT_ROOT/docs/delete-me"
print "delete me" > "$CLIENT_ROOT/docs/delete-me/local.txt"
if ! wait_for_path "$SERVER_ROOT/docs/delete-me/local.txt" 25; then
  append_report "FAIL delete regression setup upload"
  exit 1
fi

rm -rf "$CLIENT_ROOT/docs/delete-me"
if wait_for_absence "$SERVER_ROOT/docs/delete-me" 25 && wait_for_absence "$CLIENT_ROOT/docs/delete-me" 8; then
  append_report "PASS selected client deletion syncs and does not resurrect"
else
  append_report "FAIL selected client deletion resurrected or did not reach server"
  exit 1
fi

if find "$SERVER_ROOT" -name '*Conflict from*' -print -quit | grep -q .; then
  append_report "FAIL directory conflict regression produced conflict copies"
  exit 1
else
  append_report "PASS directory conflict regression did not reproduce"
fi

python3 - <<PY
import json
from pathlib import Path
path = Path("$CLIENT_CONFIG/NetworkSync.json")
data = json.loads(path.read_text())
data["includedPaths"] = ["docs", "private"]
path.write_text(json.dumps(data, indent=2))
PY
restart_client

if wait_for_path "$CLIENT_ROOT/private/hidden.txt" 25; then
  append_report "PASS selective sync add path"
else
  append_report "FAIL selective sync add path"
  exit 1
fi

python3 - <<PY
import json
from pathlib import Path
path = Path("$CLIENT_CONFIG/NetworkSync.json")
data = json.loads(path.read_text())
data["includedPaths"] = ["docs"]
path.write_text(json.dumps(data, indent=2))
PY
restart_client

if wait_for_absence "$CLIENT_ROOT/private/hidden.txt" 25; then
  append_report "PASS selective sync remove path prunes local copy"
else
  append_report "FAIL selective sync remove path prunes local copy"
  exit 1
fi

append_report ""
append_report "Logs:"
append_report "  server: $SERVER_LOG"
append_report "  client: $CLIENT_LOG"

print ""
print "Verification succeeded."
print "Workspace: $WORK_DIR"
print "Report:    $REPORT"

if [[ $KEEP_RUNNING -eq 1 ]]; then
  print "Processes left running:"
  print "  server pid: $SERVER_PID"
  print "  client pid: $CLIENT_PID"
fi
