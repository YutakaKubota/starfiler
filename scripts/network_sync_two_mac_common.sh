#!/bin/zsh
set -euo pipefail

: "${SCRIPT_DIR:?SCRIPT_DIR must be set before sourcing network_sync_two_mac_common.sh}"

REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
NS2M_APP_BIN="${APP_BIN:-/Applications/Starfiler.app/Contents/MacOS/Starfiler}"
NS2M_BUNDLE_ID="${NS2M_BUNDLE_ID:-com.nilone.starfiler}"

ns2m_usage_common_options() {
  cat <<'EOF'
Required:
  --config-root PATH      Dedicated config root for this test role
  --sync-root PATH        Dedicated sync root for this test role
  --discovery-scope TEXT  Shared discovery scope used by both Macs

Optional:
  --display-name TEXT     Bonjour/display name override
  --log-file PATH         Log file destination
  --report-file PATH      Report file destination
  --heartbeat-seconds N   Heartbeat interval (default: 5)
  --debounce-seconds N    Debounce interval (default: 0.5)
  --skip-build            Do not run build_and_install.sh
  --restart               Stop the previous role process before relaunch
  -h, --help              Show help
EOF
}

ns2m_require_value() {
  local option_name="$1"
  local value="${2:-}"
  if [[ -z "$value" ]]; then
    echo "$option_name requires a value" >&2
    exit 1
  fi
}

ns2m_require_non_empty() {
  local label="$1"
  local value="$2"
  if [[ -z "${value// }" ]]; then
    echo "$label must not be empty" >&2
    exit 1
  fi
}

ns2m_host_name() {
  local host_name=""
  host_name="$(scutil --get ComputerName 2>/dev/null || true)"
  if [[ -z "${host_name// }" ]]; then
    host_name="$(hostname -s 2>/dev/null || hostname)"
  fi
  print -r -- "${host_name:-localhost}"
}

ns2m_default_display_name() {
  local role="$1"
  local host_name
  host_name="$(ns2m_host_name)"
  case "$role" in
    server)
      print -r -- "$host_name Two Mac Server"
      ;;
    client)
      print -r -- "$host_name Two Mac Client"
      ;;
    *)
      print -r -- "$host_name"
      ;;
  esac
}

ns2m_default_log_file() {
  local config_root="$1"
  local role="$2"
  print -r -- "$config_root/network-sync-two-mac-$role.log"
}

ns2m_default_report_file() {
  local config_root="$1"
  local role="$2"
  print -r -- "$config_root/network-sync-two-mac-$role-report.txt"
}

ns2m_default_pid_file() {
  local config_root="$1"
  local role="$2"
  print -r -- "$config_root/network-sync-two-mac-$role.pid"
}

ns2m_local_config_dir() {
  local config_root="$1"
  print -r -- "$config_root/.network-sync-local/$NS2M_BUNDLE_ID/LocalConfig"
}

ns2m_network_sync_config_path() {
  local config_root="$1"
  print -r -- "$(ns2m_local_config_dir "$config_root")/NetworkSync.json"
}

ns2m_mkdirs_for_role() {
  local role="$1"
  local config_root="$2"
  local sync_root="$3"
  mkdir -p "$config_root" "$sync_root" "$(ns2m_local_config_dir "$config_root")"
  if [[ "$role" == "server" ]]; then
    mkdir -p "$sync_root/docs" "$sync_root/private"
  fi
}

ns2m_assert_distinct_paths() {
  local config_root="$1"
  local sync_root="$2"
  local config_realpath sync_realpath

  config_realpath="$(cd "$config_root" 2>/dev/null && pwd -P || true)"
  sync_realpath="$(cd "$sync_root" 2>/dev/null && pwd -P || true)"

  if [[ -n "$config_realpath" && -n "$sync_realpath" && "$config_realpath" == "$sync_realpath" ]]; then
    echo "--config-root and --sync-root must point to different directories" >&2
    exit 1
  fi
}

ns2m_directory_has_entries() {
  local directory="$1"
  if [[ ! -d "$directory" ]]; then
    return 1
  fi
  local -a entries
  setopt local_options null_glob dot_glob
  entries=("$directory"/*)
  if (( ${#entries[@]} > 0 )); then
    return 0
  fi
  return 1
}

ns2m_prepare_directory() {
  local directory="$1"
  local label="$2"
  local allow_existing="$3"

  mkdir -p "$directory"
  if [[ "$allow_existing" == "1" ]]; then
    return
  fi

  if ns2m_directory_has_entries "$directory"; then
    echo "$label must be empty for a clean two-Mac test: $directory" >&2
    echo "Use a fresh directory or rerun with --allow-existing." >&2
    exit 1
  fi
}

ns2m_write_network_sync_config() {
  local role="$1"
  local config_root="$2"
  local sync_root="$3"
  local discovery_scope="$4"
  local display_name="$5"
  local client_included_paths_csv="$6"
  local client_sync_entire_root="$7"
  local heartbeat_seconds="$8"
  local debounce_seconds="$9"
  local config_path

  config_path="$(ns2m_network_sync_config_path "$config_root")"
  export NS2M_ROLE="$role"
  export NS2M_CONFIG_PATH="$config_path"
  export NS2M_SYNC_ROOT="$sync_root"
  export NS2M_DISCOVERY_SCOPE="$discovery_scope"
  export NS2M_DISPLAY_NAME="$display_name"
  export NS2M_CLIENT_INCLUDED_PATHS_CSV="$client_included_paths_csv"
  export NS2M_CLIENT_SYNC_ENTIRE_ROOT="$client_sync_entire_root"
  export NS2M_HEARTBEAT_SECONDS="$heartbeat_seconds"
  export NS2M_DEBOUNCE_SECONDS="$debounce_seconds"

  python3 <<'PY'
import json
import os
from pathlib import Path

role = os.environ["NS2M_ROLE"]
config_path = Path(os.environ["NS2M_CONFIG_PATH"])
sync_root = os.environ["NS2M_SYNC_ROOT"]
discovery_scope = os.environ["NS2M_DISCOVERY_SCOPE"]
display_name = os.environ["NS2M_DISPLAY_NAME"]
client_sync_entire_root = os.environ["NS2M_CLIENT_SYNC_ENTIRE_ROOT"] == "true"
client_included_paths_csv = os.environ["NS2M_CLIENT_INCLUDED_PATHS_CSV"]
heartbeat_seconds = float(os.environ["NS2M_HEARTBEAT_SECONDS"])
debounce_seconds = float(os.environ["NS2M_DEBOUNCE_SECONDS"])

included_paths = [
    item.strip()
    for item in client_included_paths_csv.split(",")
    if item.strip()
]

payload = {
    "displayName": display_name,
    "discoveryScope": discovery_scope,
    "serverEnabled": role == "server",
    "serverRootPath": sync_root if role == "server" else "",
    "clientEnabled": role == "client",
    "clientRootPath": sync_root,
    "clientSyncEntireRoot": client_sync_entire_root if role == "client" else True,
    "clientIncludedPaths": included_paths if role == "client" else [],
    "conflictPolicy": "keepBoth",
    "heartbeatIntervalSeconds": heartbeat_seconds,
    "syncDebounceSeconds": debounce_seconds,
    "peers": [],
}

config_path.parent.mkdir(parents=True, exist_ok=True)
config_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
}

ns2m_seed_server_root() {
  local sync_root="$1"
  local seed_file="$sync_root/docs/seed.txt"
  local hidden_file="$sync_root/private/hidden.txt"

  if [[ ! -e "$seed_file" ]]; then
    print -r -- "seed from server" > "$seed_file"
  fi
  if [[ ! -e "$hidden_file" ]]; then
    print -r -- "hidden on first pass" > "$hidden_file"
  fi
}

ns2m_build_if_needed() {
  local skip_build="$1"
  if [[ "$skip_build" == "0" ]]; then
    "$REPO_ROOT/scripts/build_and_install.sh" --no-launch
  fi

  if [[ ! -x "$NS2M_APP_BIN" ]]; then
    echo "Starfiler app binary not found at $NS2M_APP_BIN" >&2
    exit 1
  fi
}

ns2m_append_report_header() {
  local report_file="$1"
  local role="$2"
  local config_root="$3"
  local sync_root="$4"
  local discovery_scope="$5"
  local config_path="$6"
  local log_file="$7"
  local display_name="$8"
  local client_included_paths="$9"
  local client_sync_entire_root="${10}"

  cat > "$report_file" <<EOF
Starfiler Network Sync Two-Mac Smoke
Prepared at: $(date '+%Y-%m-%d %H:%M:%S %z')
Role: $role
Display name: $display_name
Discovery scope: $discovery_scope
Config root: $config_root
Sync root: $sync_root
Actual NetworkSync.json: $config_path
Log file: $log_file
Client sync entire root: $client_sync_entire_root
Client included paths: ${client_included_paths:-docs}

Expected UI status:
- server: Server is advertising on the local network.
- client: Connected to <server name>.

Watch for:
- Skipping ...: sync scope does not match.
- Sync scope does not match.
- Set a sync root path in Network Sync settings.
- Connection lost: ...

Manual checks:
[ ] Peers state recorded (connected / rejected / offline)
[ ] Initial server -> client sync
[ ] Client -> server upload
[ ] Server -> client follow-up sync
[ ] Excluded path stays absent on client
[ ] Selective sync add path
[ ] Selective sync remove path

Recommended commands:
- cat "$config_path"
- tail -f "$log_file"

Config snapshot:
EOF
  cat "$config_path" >> "$report_file"
  cat <<'EOF' >> "$report_file"

Observations:
- Runtime status:
- Peer state:
- Failure text:

Verification notes:
- docs/seed.txt:
- docs/from-client.txt:
- docs/from-server.txt:
- private/hidden.txt:

Launch history:
EOF
}

ns2m_append_launch_entry() {
  local report_file="$1"
  local role="$2"
  local log_file="$3"
  local pid_file="$4"
  local config_path="$5"
  local sync_root="$6"
  local process_id="$7"

  cat >> "$report_file" <<EOF
- $(date '+%Y-%m-%d %H:%M:%S %z') launched $role
  pid: $process_id
  pid file: $pid_file
  sync root: $sync_root
  log file: $log_file
  config snapshot:
EOF
  sed 's/^/    /' "$config_path" >> "$report_file"
}

ns2m_stop_existing_process() {
  local pid_file="$1"
  local label="$2"

  if [[ ! -f "$pid_file" ]]; then
    return
  fi

  local existing_pid
  existing_pid="$(<"$pid_file")"
  if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
    kill "$existing_pid" 2>/dev/null || true
    wait "$existing_pid" 2>/dev/null || true
    print -r -- "Stopped existing $label process: $existing_pid"
  fi
  rm -f "$pid_file"
}

ns2m_assert_not_running() {
  local pid_file="$1"
  local label="$2"

  if [[ ! -f "$pid_file" ]]; then
    return
  fi

  local existing_pid
  existing_pid="$(<"$pid_file")"
  if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
    echo "$label already appears to be running with pid $existing_pid" >&2
    echo "Use --restart to stop the previous process first." >&2
    exit 1
  fi
  rm -f "$pid_file"
}

ns2m_launch_role() {
  local role="$1"
  local config_root="$2"
  local sync_root="$3"
  local log_file="$4"
  : > "$log_file"

  open -n -a "/Applications/Starfiler.app" --args \
    --uitest \
    --disable-animations \
    --config-root "$config_root" \
    --sandbox-root "$sync_root"

  local pid=""
  local attempt=0
  while (( attempt < 20 )); do
    pid="$(
      ps -axo pid=,command= \
        | grep -F "/Applications/Starfiler.app/Contents/MacOS/Starfiler" \
        | grep -F -- "--config-root $config_root" \
        | grep -F -- "--sandbox-root $sync_root" \
        | tail -n 1 \
        | awk '{print $1}'
    )"
    if [[ -n "$pid" ]]; then
      print -r -- "$pid"
      return 0
    fi
    sleep 0.5
    (( attempt += 1 ))
  done

  echo "Failed to find launched $role process for config root $config_root" >&2
  return 1
}
