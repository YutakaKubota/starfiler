#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/network_sync_two_mac_common.sh"

usage() {
  cat <<'EOF'
Usage: ./scripts/network_sync_two_mac_prepare.sh --role server|client --config-root PATH --sync-root PATH --discovery-scope TEXT [options]

Prepare a clean two-Mac Network Sync workspace for either the server or client Mac.

Options:
  --role server|client    Which role this Mac will run
  --allow-existing        Reuse non-empty directories instead of requiring a clean workspace
  --client-included-paths CSV
                          Comma-separated client paths (default: docs)
  --client-sync-entire-root true|false
                          Client whole-root sync flag (default: false)
EOF
  ns2m_usage_common_options
}

ROLE=""
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
ALLOW_EXISTING="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role)
      shift
      ROLE="${1:-}"
      ns2m_require_value --role "$ROLE"
      ;;
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
    --allow-existing)
      ALLOW_EXISTING="1"
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

case "$ROLE" in
  server|client)
    ;;
  *)
    echo "--role must be server or client" >&2
    usage >&2
    exit 1
    ;;
esac

ns2m_require_non_empty --config-root "$CONFIG_ROOT"
ns2m_require_non_empty --sync-root "$SYNC_ROOT"
ns2m_require_non_empty --discovery-scope "$DISCOVERY_SCOPE"
ns2m_assert_distinct_paths "$CONFIG_ROOT" "$SYNC_ROOT"

DISPLAY_NAME="${DISPLAY_NAME:-$(ns2m_default_display_name "$ROLE")}"
LOG_FILE="${LOG_FILE:-$(ns2m_default_log_file "$CONFIG_ROOT" "$ROLE")}"
REPORT_FILE="${REPORT_FILE:-$(ns2m_default_report_file "$CONFIG_ROOT" "$ROLE")}"
CONFIG_PATH="$(ns2m_network_sync_config_path "$CONFIG_ROOT")"
REPORT_CLIENT_INCLUDED_PATHS="$CLIENT_INCLUDED_PATHS"
REPORT_CLIENT_SYNC_ENTIRE_ROOT="$CLIENT_SYNC_ENTIRE_ROOT"

if [[ "$ROLE" == "server" ]]; then
  REPORT_CLIENT_INCLUDED_PATHS="n/a (server role)"
  REPORT_CLIENT_SYNC_ENTIRE_ROOT="n/a (server role)"
fi

ns2m_prepare_directory "$CONFIG_ROOT" "--config-root" "$ALLOW_EXISTING"
ns2m_prepare_directory "$SYNC_ROOT" "--sync-root" "$ALLOW_EXISTING"
ns2m_mkdirs_for_role "$ROLE" "$CONFIG_ROOT" "$SYNC_ROOT"
ns2m_write_network_sync_config \
  "$ROLE" \
  "$CONFIG_ROOT" \
  "$SYNC_ROOT" \
  "$DISCOVERY_SCOPE" \
  "$DISPLAY_NAME" \
  "$CLIENT_INCLUDED_PATHS" \
  "$CLIENT_SYNC_ENTIRE_ROOT" \
  "$HEARTBEAT_SECONDS" \
  "$DEBOUNCE_SECONDS"

if [[ "$ROLE" == "server" ]]; then
  ns2m_seed_server_root "$SYNC_ROOT"
fi

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$REPORT_FILE")"
touch "$LOG_FILE"
ns2m_append_report_header \
  "$REPORT_FILE" \
  "$ROLE" \
  "$CONFIG_ROOT" \
  "$SYNC_ROOT" \
  "$DISCOVERY_SCOPE" \
  "$CONFIG_PATH" \
  "$LOG_FILE" \
  "$DISPLAY_NAME" \
  "$REPORT_CLIENT_INCLUDED_PATHS" \
  "$REPORT_CLIENT_SYNC_ENTIRE_ROOT"

cat <<EOF
Prepared two-Mac Network Sync workspace.
Role:               $ROLE
Display name:       $DISPLAY_NAME
Discovery scope:    $DISCOVERY_SCOPE
Config root:        $CONFIG_ROOT
Sync root:          $SYNC_ROOT
NetworkSync.json:   $CONFIG_PATH
Log file:           $LOG_FILE
Report file:        $REPORT_FILE

Next step:
  ./scripts/network_sync_two_mac_${ROLE}.sh --config-root "$CONFIG_ROOT" --sync-root "$SYNC_ROOT" --discovery-scope "$DISCOVERY_SCOPE"
EOF
