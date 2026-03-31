#!/usr/bin/env bash
# setup_watch.sh — launchd で auto_pull_and_build.sh を定期実行するセットアップ
# 他のMacでも同じスクリプトを実行するだけで設定完了
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PULL_BUILD_SCRIPT="$SCRIPT_DIR/auto_pull_and_build.sh"

LABEL="com.starfiler.auto-pull-build"
PLIST_PATH="$HOME/Library/LaunchAgents/${LABEL}.plist"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-30}"
LOG_FILE="$HOME/.starfiler-auto-sync.log"

ACTION="${1:-install}"

usage() {
  cat <<'EOF'
Usage: setup_watch.sh [install|uninstall|status]

  install     launchd エージェントをインストールして起動 (default)
  uninstall   launchd エージェントを停止・削除
  status      現在の状態を表示

Environment:
  INTERVAL_SECONDS  チェック間隔（秒、デフォルト: 30）
EOF
}

do_install() {
  echo "=== Starfiler Auto-Pull & Build セットアップ ==="
  echo ""

  # Ensure scripts are executable
  chmod +x "$PULL_BUILD_SCRIPT"
  chmod +x "$SCRIPT_DIR/auto-pull.sh"
  chmod +x "$SCRIPT_DIR/../build_and_install.sh"

  # Unload existing if present
  if launchctl list "$LABEL" &>/dev/null; then
    echo "[1/3] 既存エージェントをアンロード..."
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || \
      launchctl unload "$PLIST_PATH" 2>/dev/null || true
  fi

  # Create plist
  echo "[2/3] launchd plist を作成..."
  mkdir -p "$(dirname "$PLIST_PATH")"
  cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${PULL_BUILD_SCRIPT}</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${REPO_DIR}</string>
  <key>StartInterval</key>
  <integer>${INTERVAL_SECONDS}</integer>
  <key>StandardOutPath</key>
  <string>${LOG_FILE}</string>
  <key>StandardErrorPath</key>
  <string>${LOG_FILE}</string>
  <key>RunAtLoad</key>
  <true/>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HOME</key>
    <string>${HOME}</string>
  </dict>
</dict>
</plist>
PLIST

  # Load
  echo "[3/3] エージェントをロード..."
  launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || \
    launchctl load "$PLIST_PATH" 2>/dev/null || true

  echo ""
  echo "=== セットアップ完了 ==="
  echo ""
  echo "  チェック間隔: ${INTERVAL_SECONDS}秒"
  echo "  Plist:        $PLIST_PATH"
  echo "  ログ:         $LOG_FILE"
  echo ""
  echo "動作確認:"
  echo "  tail -f $LOG_FILE"
  echo ""
  echo "停止するには:"
  echo "  bash $SCRIPT_DIR/setup_watch.sh uninstall"
}

do_uninstall() {
  echo "=== Starfiler Auto-Pull & Build アンインストール ==="
  echo ""

  if launchctl list "$LABEL" &>/dev/null; then
    echo "エージェントを停止..."
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || \
      launchctl unload "$PLIST_PATH" 2>/dev/null || true
  fi

  if [ -f "$PLIST_PATH" ]; then
    echo "Plist を削除: $PLIST_PATH"
    rm -f "$PLIST_PATH"
  fi

  echo ""
  echo "アンインストール完了"
}

do_status() {
  echo "=== Starfiler Auto-Pull & Build ステータス ==="
  echo ""

  if [ -f "$PLIST_PATH" ]; then
    echo "Plist: $PLIST_PATH (存在)"
  else
    echo "Plist: $PLIST_PATH (未インストール)"
    return
  fi

  if launchctl list "$LABEL" &>/dev/null; then
    echo "状態: 実行中"
    launchctl list "$LABEL" 2>/dev/null | head -5
  else
    echo "状態: 停止中"
  fi

  echo ""
  echo "最新ログ:"
  tail -5 "$LOG_FILE" 2>/dev/null || echo "  (ログなし)"
}

case "$ACTION" in
  install)   do_install ;;
  uninstall) do_uninstall ;;
  status)    do_status ;;
  -h|--help) usage ;;
  *)
    echo "Unknown action: $ACTION" >&2
    usage >&2
    exit 1
    ;;
esac
