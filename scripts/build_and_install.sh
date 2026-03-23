#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PROJECT_DIR="$REPO_ROOT/starfiler-app"
PROJECT_FILE="$PROJECT_DIR/starfiler.xcodeproj"
SCHEME="${SCHEME:-starfiler}"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$PROJECT_DIR/.derivedData}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"
CODE_SIGN_STYLE_SETTING="${CODE_SIGN_STYLE:-}"
PROVISIONING_PROFILE_SPECIFIER="${PROVISIONING_PROFILE_SPECIFIER:-}"
APP_NAME="${APP_NAME:-Starfiler.app}"
APP_SOURCE="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME"
APP_DEST="${APP_DEST:-/Applications/$APP_NAME}"
PROCESS_NAME="${APP_NAME%.app}"
LEGACY_APP_DEST="/Applications/starfiler.app"
LEGACY_PROCESS_NAME="starfiler"
EXECUTABLE_NAME="${EXECUTABLE_NAME:-${APP_NAME%.app}}"
SOURCE_EXECUTABLE="$APP_SOURCE/Contents/MacOS/$EXECUTABLE_NAME"
DEST_EXECUTABLE="$APP_DEST/Contents/MacOS/$EXECUTABLE_NAME"
NORMALIZED_APP_DEST="$(printf '%s' "$APP_DEST" | /usr/bin/tr '[:upper:]' '[:lower:]')"
NORMALIZED_LEGACY_APP_DEST="$(printf '%s' "$LEGACY_APP_DEST" | /usr/bin/tr '[:upper:]' '[:lower:]')"

LAUNCH_AFTER_INSTALL=true
QUIET=false
STOP_RUNNING_PROCESS=false

usage() {
  cat <<'EOF'
Usage: scripts/build_and_install.sh [options]

Options:
  --launch       Launch app after install (default)
  --no-launch    Install only
  --stop-running Stop running app process before install (legacy behavior)
  --quiet        Quiet xcodebuild output
  -h, --help     Show this help
EOF
}

while (($#)); do
  case "$1" in
    --launch)
      LAUNCH_AFTER_INSTALL=true
      ;;
    --no-launch)
      LAUNCH_AFTER_INSTALL=false
      ;;
    --stop-running)
      STOP_RUNNING_PROCESS=true
      ;;
    --quiet)
      QUIET=true
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

if [[ ! -d "$PROJECT_DIR" ]]; then
  echo "Project directory not found: $PROJECT_DIR" >&2
  exit 1
fi

echo "[build] scheme=$SCHEME configuration=$CONFIGURATION"
echo "[build] derivedData=$DERIVED_DATA_PATH"

IDENTITY_OUTPUT="$({ /usr/bin/security find-identity -v -p codesigning 2>/dev/null || true; })"

if [[ -z "$DEVELOPMENT_TEAM" ]]; then
  AUTO_DETECTED_TEAM="$(printf '%s\n' "$IDENTITY_OUTPUT" \
    | /usr/bin/grep -Eo '\([A-Z0-9]{10}\)' \
    | /usr/bin/tr -d '()' \
    | /usr/bin/sort -u || true)"
  TEAM_COUNT="$(printf '%s\n' "$AUTO_DETECTED_TEAM" | /usr/bin/sed '/^$/d' | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
  if [[ "$TEAM_COUNT" == "1" ]]; then
    DEVELOPMENT_TEAM="$AUTO_DETECTED_TEAM"
    echo "[sign] auto-detected DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM"
  elif [[ "$TEAM_COUNT" -gt 1 ]]; then
    echo "[sign] multiple code signing teams detected; set DEVELOPMENT_TEAM to use non-adhoc signing"
  else
    echo "[sign] no code signing identity found; falling back to ad-hoc signing"
  fi
fi

identity_available_for_team() {
  local identity_kind="$1"
  if [[ -n "$DEVELOPMENT_TEAM" ]]; then
    printf '%s\n' "$IDENTITY_OUTPUT" | /usr/bin/grep -Eq "\"$identity_kind: .*\($DEVELOPMENT_TEAM\)\""
  else
    printf '%s\n' "$IDENTITY_OUTPUT" | /usr/bin/grep -Fq "\"$identity_kind:"
  fi
}

if [[ -n "$DEVELOPMENT_TEAM" ]] && [[ -z "$CODE_SIGN_IDENTITY" ]]; then
  if identity_available_for_team "Apple Development"; then
    CODE_SIGN_IDENTITY="Apple Development"
    echo "[sign] auto-selected CODE_SIGN_IDENTITY=$CODE_SIGN_IDENTITY"
  elif identity_available_for_team "Mac Development"; then
    CODE_SIGN_IDENTITY="Mac Development"
    echo "[sign] auto-selected CODE_SIGN_IDENTITY=$CODE_SIGN_IDENTITY"
  elif identity_available_for_team "Apple Distribution"; then
    CODE_SIGN_IDENTITY="Apple Distribution"
    echo "[sign] auto-selected CODE_SIGN_IDENTITY=$CODE_SIGN_IDENTITY"
  else
    echo "[sign] no matching identity found for DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM; falling back to ad-hoc signing"
  fi
fi

if [[ -n "$DEVELOPMENT_TEAM" ]] && [[ -n "$CODE_SIGN_IDENTITY" ]] && [[ -z "$CODE_SIGN_STYLE_SETTING" ]]; then
  if [[ "$CODE_SIGN_IDENTITY" == "Apple Distribution" ]]; then
    CODE_SIGN_STYLE_SETTING="Manual"
  else
    CODE_SIGN_STYLE_SETTING="Automatic"
  fi
fi

XCODEBUILD_ARGS=(
  -project "$PROJECT_FILE"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -derivedDataPath "$DERIVED_DATA_PATH"
  build
)

if [[ -n "$DEVELOPMENT_TEAM" ]] && [[ -n "$CODE_SIGN_IDENTITY" ]] && [[ -n "$CODE_SIGN_STYLE_SETTING" ]]; then
  echo "[sign] using CODE_SIGN_IDENTITY=$CODE_SIGN_IDENTITY CODE_SIGN_STYLE=$CODE_SIGN_STYLE_SETTING"
  XCODEBUILD_ARGS+=(
    "DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM"
    "CODE_SIGN_IDENTITY=$CODE_SIGN_IDENTITY"
    "CODE_SIGN_STYLE=$CODE_SIGN_STYLE_SETTING"
  )
  if [[ "$CODE_SIGN_STYLE_SETTING" == "Manual" ]]; then
    XCODEBUILD_ARGS+=("PROVISIONING_PROFILE_SPECIFIER=$PROVISIONING_PROFILE_SPECIFIER")
  fi
fi

if [[ "$QUIET" == true ]]; then
  /usr/bin/xcodebuild "${XCODEBUILD_ARGS[@]}" -quiet
else
  /usr/bin/xcodebuild "${XCODEBUILD_ARGS[@]}"
fi

if [[ ! -d "$APP_SOURCE" ]]; then
  echo "Built app not found: $APP_SOURCE" >&2
  exit 1
fi

PROCESS_IS_RUNNING=false
LEGACY_PROCESS_IS_RUNNING=false

if /usr/bin/pgrep -x "$PROCESS_NAME" >/dev/null 2>&1; then
  PROCESS_IS_RUNNING=true
fi

if [[ "$APP_DEST" == "/Applications/Starfiler.app" ]] && /usr/bin/pgrep -x "$LEGACY_PROCESS_NAME" >/dev/null 2>&1; then
  LEGACY_PROCESS_IS_RUNNING=true
fi

if [[ "$STOP_RUNNING_PROCESS" == true ]]; then
  if [[ "$PROCESS_IS_RUNNING" == true ]]; then
    echo "[install] stopping running process: $PROCESS_NAME"
    /usr/bin/pkill -x "$PROCESS_NAME" || true
    /bin/sleep 0.3
    PROCESS_IS_RUNNING=false
  fi

  if [[ "$LEGACY_PROCESS_IS_RUNNING" == true ]]; then
    echo "[install] stopping legacy process: $LEGACY_PROCESS_NAME"
    /usr/bin/pkill -x "$LEGACY_PROCESS_NAME" || true
    /bin/sleep 0.3
    LEGACY_PROCESS_IS_RUNNING=false
  fi
else
  if [[ "$PROCESS_IS_RUNNING" == true ]]; then
    echo "[install] detected running process: $PROCESS_NAME (kept alive; update applies fully after relaunch)"
  fi
  if [[ "$LEGACY_PROCESS_IS_RUNNING" == true ]]; then
    echo "[install] detected running legacy process: $LEGACY_PROCESS_NAME (legacy cleanup skipped)"
  fi
fi

echo "[install] $APP_DEST"
if [[ -d "$APP_DEST" ]]; then
  if [[ "$PROCESS_IS_RUNNING" == true ]]; then
    echo "[install] syncing app bundle contents without deleting existing bundle"
    /usr/bin/ditto "$APP_SOURCE/Contents" "$APP_DEST/Contents"
  else
    echo "[install] updating existing app bundle in-place"
    /bin/rm -rf "$APP_DEST/Contents"
    /usr/bin/ditto "$APP_SOURCE/Contents" "$APP_DEST/Contents"
  fi
else
  /bin/cp -R "$APP_SOURCE" "$APP_DEST"
fi

if [[ "$APP_DEST" == "/Applications/Starfiler.app" ]] && [[ "$NORMALIZED_APP_DEST" != "$NORMALIZED_LEGACY_APP_DEST" ]] && [[ -d "$LEGACY_APP_DEST" ]]; then
  if [[ "$LEGACY_PROCESS_IS_RUNNING" == true ]]; then
    echo "[install] skipping legacy app removal while running: $LEGACY_APP_DEST"
  else
    echo "[install] removing legacy app: $LEGACY_APP_DEST"
    /bin/rm -rf "$LEGACY_APP_DEST"
  fi
fi

/usr/bin/xattr -dr com.apple.quarantine "$APP_DEST" >/dev/null 2>&1 || true
/usr/bin/codesign --verify --deep --strict "$APP_DEST"

SIGNATURE_INFO="$(/usr/bin/codesign -dvv "$APP_DEST" 2>&1)"
if printf '%s' "$SIGNATURE_INFO" | /usr/bin/grep -Fq 'Signature=adhoc'; then
  echo "[sign] installed app is ad-hoc signed"
  echo "[sign] ad-hoc signing may cause folder access prompts on every rebuild"
  echo "[sign] set DEVELOPMENT_TEAM (and optionally CODE_SIGN_IDENTITY) to persist permissions"
else
  SIGNER_LINE="$(printf '%s\n' "$SIGNATURE_INFO" | /usr/bin/grep '^Authority=' | /usr/bin/head -n 1 || true)"
  if [[ -n "$SIGNER_LINE" ]]; then
    echo "[sign] ${SIGNER_LINE#Authority=}"
  else
    echo "[sign] installed app is signed with a non-adhoc identity"
  fi
fi

if [[ ! -f "$SOURCE_EXECUTABLE" ]]; then
  echo "Source executable not found: $SOURCE_EXECUTABLE" >&2
  exit 1
fi

if [[ ! -f "$DEST_EXECUTABLE" ]]; then
  echo "Installed executable not found: $DEST_EXECUTABLE" >&2
  exit 1
fi

SOURCE_HASH="$(/usr/bin/shasum -a 256 "$SOURCE_EXECUTABLE" | /usr/bin/awk '{print $1}')"
DEST_HASH="$(/usr/bin/shasum -a 256 "$DEST_EXECUTABLE" | /usr/bin/awk '{print $1}')"
if [[ "$SOURCE_HASH" != "$DEST_HASH" ]]; then
  echo "Install verification failed: source and destination binaries differ." >&2
  echo "source: $SOURCE_EXECUTABLE" >&2
  echo "dest:   $DEST_EXECUTABLE" >&2
  exit 1
fi
echo "[verify] installed binary hash matches build output ($DEST_HASH)"

if [[ "$LAUNCH_AFTER_INSTALL" == true ]]; then
  if /usr/bin/pgrep -x "$PROCESS_NAME" >/dev/null 2>&1; then
    echo "[launch] stopping running process before relaunch: $PROCESS_NAME"
    /usr/bin/pkill -x "$PROCESS_NAME" || true
    /bin/sleep 0.5
  fi
  echo "[launch] opening $APP_DEST"
  /usr/bin/open -a "$APP_DEST"
fi

echo "[done] installed $APP_DEST"
