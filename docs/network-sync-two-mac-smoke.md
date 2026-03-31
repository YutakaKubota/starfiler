# Network Sync Two-Mac Smoke

別Mac間で `Connected` までは行くが同期されない問題を、専用 config / 専用 root / 専用 discovery scope で切り分けるための手順です。

この手順では、Server Mac と Client Mac の両方で専用ディレクトリを使います。実運用の設定や root を流用せず、まずは最小構成で同期を通します。

## 目的

- 両Macで `NetworkSync.json` の実保存先を固定する
- `Server Role` と `Client Role` を明示的に分離する
- `docs` のみを同期対象にした最小ケースを再現する
- `server -> client` と `client -> server` の両方向更新を確認する
- 選択同期の追加と解除を同じ条件で再試行できるようにする

## 使うスクリプト

- [network_sync_two_mac_prepare.sh](/Users/workspace/NilOne/starfiler/scripts/network_sync_two_mac_prepare.sh)
- [network_sync_two_mac_server.sh](/Users/workspace/NilOne/starfiler/scripts/network_sync_two_mac_server.sh)
- [network_sync_two_mac_client.sh](/Users/workspace/NilOne/starfiler/scripts/network_sync_two_mac_client.sh)

## 事前条件

- 両Macにこのリポジトリがある
- 両Macで `/Applications/Starfiler.app` を起動できる
- 両Macが同一LANにいる
- 両Macで Local Network 権限を許可できる

## 推奨ディレクトリ

Server Mac:

```bash
CONFIG_ROOT="$HOME/tmp/starfiler-two-mac/server-config"
SYNC_ROOT="$HOME/tmp/starfiler-two-mac/server-root"
DISCOVERY_SCOPE="two-mac-smoke-$(date +%Y%m%d-%H%M%S)"
```

Client Mac:

```bash
CONFIG_ROOT="$HOME/tmp/starfiler-two-mac/client-config"
SYNC_ROOT="$HOME/tmp/starfiler-two-mac/client-root"
DISCOVERY_SCOPE="<Server Mac と同じ値>"
```

## 1. Server Mac を準備

```bash
cd /Users/workspace/NilOne/starfiler
./scripts/network_sync_two_mac_prepare.sh \
  --role server \
  --config-root "$CONFIG_ROOT" \
  --sync-root "$SYNC_ROOT" \
  --discovery-scope "$DISCOVERY_SCOPE"
```

この時点で次が作られます。

- `docs/seed.txt`
- `private/hidden.txt`
- 実保存先の `NetworkSync.json`
- ログファイル
- 手動検証用レポート

## 2. Client Mac を準備

```bash
cd /Users/workspace/NilOne/starfiler
./scripts/network_sync_two_mac_prepare.sh \
  --role client \
  --config-root "$CONFIG_ROOT" \
  --sync-root "$SYNC_ROOT" \
  --discovery-scope "$DISCOVERY_SCOPE" \
  --client-included-paths docs
```

既定では `clientSyncEntireRoot=false`、`clientIncludedPaths=["docs"]` です。

## 3. Server Mac を起動

```bash
cd /Users/workspace/NilOne/starfiler
./scripts/network_sync_two_mac_server.sh \
  --config-root "$CONFIG_ROOT" \
  --sync-root "$SYNC_ROOT" \
  --discovery-scope "$DISCOVERY_SCOPE"
```

期待する UI 状態:

- `Server is advertising on the local network.`

## 4. Client Mac を起動

```bash
cd /Users/workspace/NilOne/starfiler
./scripts/network_sync_two_mac_client.sh \
  --config-root "$CONFIG_ROOT" \
  --sync-root "$SYNC_ROOT" \
  --discovery-scope "$DISCOVERY_SCOPE" \
  --client-included-paths docs
```

期待する UI 状態:

- `Connected to <server name>.`

## 5. 実ファイルで確認する順序

1. Client Mac に `"$SYNC_ROOT/docs/seed.txt"` が現れる
2. Client Mac で `"$SYNC_ROOT/docs/from-client.txt"` を作り、Server Mac に反映される
3. Server Mac で `"$SYNC_ROOT/docs/from-server.txt"` を作り、Client Mac に反映される
4. Client Mac に `"$SYNC_ROOT/private/hidden.txt"` が存在しない
5. Client 側の `clientIncludedPaths` に `private` を追加して再起動し、`hidden.txt` が取得される
6. `private` を再度外して再起動し、Client 側から `hidden.txt` が消える

## 実設定の確認

UI ではなく、実保存先の `NetworkSync.json` を正とします。各スクリプトは起動時にレポートへ config snapshot を追記します。

確認コマンド例:

```bash
cat "$CONFIG_ROOT/.network-sync-local/com.nilone.starfiler/LocalConfig/NetworkSync.json"
```

## ログとレポート

既定の生成物:

- `"$CONFIG_ROOT/network-sync-two-mac-server.log"`
- `"$CONFIG_ROOT/network-sync-two-mac-server-report.txt"`
- `"$CONFIG_ROOT/network-sync-two-mac-client.log"`
- `"$CONFIG_ROOT/network-sync-two-mac-client-report.txt"`

ログ監視:

```bash
tail -f "$CONFIG_ROOT/network-sync-two-mac-server.log"
tail -f "$CONFIG_ROOT/network-sync-two-mac-client.log"
```

重点確認する失敗文言:

- `Skipping ...: sync scope does not match.`
- `Sync scope does not match.`
- `Set a sync root path in Network Sync settings.`
- `Connection lost: ...`

## 再試行

同じ config-root / sync-root で起動し直す場合:

```bash
./scripts/network_sync_two_mac_server.sh --config-root "$CONFIG_ROOT" --sync-root "$SYNC_ROOT" --discovery-scope "$DISCOVERY_SCOPE" --restart
./scripts/network_sync_two_mac_client.sh --config-root "$CONFIG_ROOT" --sync-root "$SYNC_ROOT" --discovery-scope "$DISCOVERY_SCOPE" --restart
```

同じ条件で最低 3 回連続で再現し、各回の観測をレポートへ追記します。
