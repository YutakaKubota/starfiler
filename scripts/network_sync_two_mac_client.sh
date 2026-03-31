#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/network_sync_two_mac_common.sh"

usage() {
  cat <<'EOF'
Usage: ./scripts/network_sync_two_mac_client.sh --config-root PATH --sync-root PATH --discovery-scope TEXT [options]

Launch the dedicated two-Mac client instance with a fixed Client Role config.

Options:
  --client-included-paths CSV
                          Comma-separated client selective sync paths (default: docs)
  --client-sync-entire-root true|false
                          Client whole-root sync flag (default: false)
EOF
  ns2m_usage_common_options
}

CONFIG_ROOT=""
SYNC_ROOT=""
DISCOVERY_SCOPE=""
DISPLAY_NAME=""
LOG_FILE=""
REPORT_FILE=""
CLIENT_INCLUDED_PATHS="docs"
CLIENT_SYNC_ENTIRE_ROOT="false"
HEARTBEAT_SECONDS="5"
DEBOUNCE_SECONDS="0.5"
SKIP_BUILD="0"
RESTART="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config-root)
      shift
      CONFIG_ROOT="${1:-}"
      ns2m_require_value --config-root "$CONFIG_ROOT"
      ;;
    --sync-root)
      shift
      SYNC_ROOT="${1:-}"
      ns2m_require_value --sync-root "$SYNC_ROOT"
      ;;
    --discovery-scope)
      shift
      DISCOVERY_SCOPE="${1:-}"
      ns2m_require_value --discovery-scope "$DISCOVERY_SCOPE"
      ;;
    --display-name)
      shift
      DISPLAY_NAME="${1:-}"
      ns2m_require_value --display-name "$DISPLAY_NAME"
      ;;
    --log-file)
      shift
      LOG_FILE="${1:-}"
      ns2m_require_value --log-file "$LOG_FILE"
      ;;
    --report-file)
      shift
      REPORT_FILE="${1:-}"
      ns2m_require_value --report-file "$REPORT_FILE"
      ;;
    --client-included-paths)
      shift
      CLIENT_INCLUDED_PATHS="${1:-}"
      ns2m_require_value --client-included-paths "$CLIENT_INCLUDED_PATHS"
      ;;
    --client-sync-entire-root)
      shift
      CLIENT_SYNC_ENTIRE_ROOT="${1:-}"
      ns2m_require_value --client-sync-entire-root "$CLIENT_SYNC_ENTIRE_ROOT"
      ;;
    --heartbeat-seconds)
      shift
      HEARTBEAT_SECONDS="${1:-}"
      ns2m_require_value --heartbeat-seconds "$HEARTBEAT_SECONDS"
      ;;
    --debounce-seconds)
      shift
      DEBOUNCE_SECONDS="${1:-}"
      ns2m_require_value --debounce-seconds "$DEBOUNCE_SECONDS"
      ;;
    --skip-build)
      SKIP_BUILD="1"
      ;;
    --restart)
      RESTART="1"
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

ns2m_require_non_empty --config-root "$CONFIG_ROOT"
ns2m_require_non_empty --sync-root "$SYNC_ROOT"
ns2m_require_non_empty --discovery-scope "$DISCOVERY_SCOPE"
ns2m_assert_distinct_paths "$CONFIG_ROOT" "$SYNC_ROOT"

DISPLAY_NAME="${DISPLAY_NAME:-$(ns2m_default_display_name client)}"
LOG_FILE="${LOG_FILE:-$(ns2m_default_log_file "$CONFIG_ROOT" client)}"
REPORT_FILE="${REPORT_FILE:-$(ns2m_default_report_file "$CONFIG_ROOT" client)}"
PID_FILE="$(ns2m_default_pid_file "$CONFIG_ROOT" client)"
CONFIG_PATH="$(ns2m_network_sync_config_path "$CONFIG_ROOT")"

ns2m_mkdirs_for_role client "$CONFIG_ROOT" "$SYNC_ROOT"
mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$REPORT_FILE")"
touch "$LOG_FILE"

ns2m_write_network_sync_config \
  client \
  "$CONFIG_ROOT" \
  "$SYNC_ROOT" \
  "$DISCOVERY_SCOPE" \
  "$DISPLAY_NAME" \
  "$CLIENT_INCLUDED_PATHS" \
  "$CLIENT_SYNC_ENTIRE_ROOT" \
  "$HEARTBEAT_SECONDS" \
  "$DEBOUNCE_SECONDS"

if [[ ! -f "$REPORT_FILE" ]]; then
  ns2m_append_report_header \
    "$REPORT_FILE" \
    client \
    "$CONFIG_ROOT" \
    "$SYNC_ROOT" \
    "$DISCOVERY_SCOPE" \
    "$CONFIG_PATH" \
    "$LOG_FILE" \
    "$DISPLAY_NAME" \
    "$CLIENT_INCLUDED_PATHS" \
    "$CLIENT_SYNC_ENTIRE_ROOT"
fi

if [[ "$RESTART" == "1" ]]; then
  ns2m_stop_existing_process "$PID_FILE" "two-Mac client"
else
  ns2m_assert_not_running "$PID_FILE" "two-Mac client"
fi

ns2m_build_if_needed "$SKIP_BUILD"
PROCESS_ID="$(ns2m_launch_role client "$CONFIG_ROOT" "$SYNC_ROOT" "$LOG_FILE")"
print -r -- "$PROCESS_ID" > "$PID_FILE"
ns2m_append_launch_entry "$REPORT_FILE" client "$LOG_FILE" "$PID_FILE" "$CONFIG_PATH" "$SYNC_ROOT" "$PROCESS_ID"

cat <<EOF
Two-Mac client launched.
PID:               $PROCESS_ID
Config root:       $CONFIG_ROOT
Sync root:         $SYNC_ROOT
NetworkSync.json:  $CONFIG_PATH
Log file:          $LOG_FILE
Report file:       $REPORT_FILE

Expected UI status:
  Connected to <server name>.

Tail logs:
  tail -f "$LOG_FILE"
EOF

