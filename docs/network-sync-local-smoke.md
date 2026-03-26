# Network Sync Local Smoke

1 台の Mac だけで `Server` と `Client` を別設定で起動し、Network Sync を再現確認するための手順です。

## 目的

- `Server` と `Client` を別 root / 別 config で起動する
- 基本同期を確認する
- 選択同期の追加と解除を確認する
- フォルダ変更で無駄な `Conflict from ...` が増えないことを確認する

## 実行

```bash
cd /Users/workspace/NilOne/starfiler
./scripts/network_sync_local_smoke.sh
```

ビルド済みアプリをそのまま使うなら:

```bash
./scripts/network_sync_local_smoke.sh --skip-build
```

検証後も 2 インスタンスを残して Finder で見たいなら:

```bash
./scripts/network_sync_local_smoke.sh --keep-running
```

## スクリプトがやること

- `/Applications/Starfiler.app` を 2 プロセス起動する
- `server-root` と `client-root` を別ディレクトリに作る
- `server-config` と `client-config` を別ディレクトリに作る
- `discoveryScope` を専用値にして、既存の Starfiler 実運用インスタンスへ誤接続しないようにする
- `docs` だけ同期対象にした状態で初回同期を確認する
- `client -> server` のファイル作成を確認する
- `server -> client` のファイル作成を確認する
- ネストしたフォルダ作成で不要な conflict が出ないことを確認する
- `private` を選択同期に追加して取得を確認する
- `private` を選択解除してローカル削除を確認する

## 生成物

スクリプトは一時ディレクトリを作り、最後にその場所を表示します。中には次が入ります。

- `server-root`
- `client-root`
- `server-config/NetworkSync.json`
- `client-config/NetworkSync.json`
- `server.log`
- `client.log`
- `verification-report.txt`

## 補足

同一 Mac 検証で `Server` と `Client` をちゃんと別端末扱いにするため、Network Sync の `deviceID` は `config-root` ごとに保存されます。`--config-root` を分けて起動すれば、1 台でも再現しやすくなります。
