---
name: sync
description: pull・コミット・pushをまとめて実行。変更の自動グルーピングとコンフリクト解消も行う。
---

# Sync

pull → コミット → push をまとめて実行する。
変更内容を分析して意味のある単位にグルーピングし、コンフリクトがあればコードを理解して解消する。

## 使用方法

```
/sync              # sync（pull → コミット → push）※デフォルト
/sync commit       # コミットのみ
/sync push         # コミット → push
/sync pull         # pull → コミット
```

`$ARGUMENTS` を解析してモードを決定する。引数なしの場合は **sync**（pull → コミット → push）。

## 実行フロー

```
[pull モード / sync モード]
  ↓ pull --rebase
  ↓ コンフリクトがあれば解消
[全モード共通]
  ↓ 変更を分析・グルーピング
  ↓ コミット
[push モード / sync モード]
  ↓ push
```

---

## Phase 1: Pull（pull / sync モードのみ）

### 1-1. リモートの状態を確認

```bash
git fetch origin
git status
git log --oneline HEAD..origin/$(git branch --show-current) -- 2>/dev/null  # リモートの未取得コミットを表示
```

リモートに新しいコミットがなければ pull をスキップ。

### 1-2. ローカル変更の退避

uncommitted な変更がある場合は stash してから pull する。

```bash
git stash push -m "smart-commit: pull前の自動退避"
```

### 1-3. Pull（rebase）

```bash
git pull --rebase origin $(git branch --show-current)
```

成功したら stash を戻す:

```bash
git stash pop  # stash した場合のみ復元
```

### 1-4. コンフリクト解消

pull --rebase でコンフリクトが発生した場合:

1. `git diff --name-only --diff-filter=U` でコンフリクトファイル一覧を取得
2. **各ファイルのコンフリクト内容を Read ツールで読む**
3. **コンフリクトの両側（ours / theirs）のコードの意図を理解する**:
   - `git log --oneline -5 -- <file>` でファイルの最近の変更履歴を確認
   - コンフリクトマーカー（`<<<<<<<`, `=======`, `>>>>>>>`）の前後のコードを読んで文脈を把握
   - 必要に応じて関連ファイル（import先、呼び出し元）も読んで影響範囲を確認
4. **解消方針を決定**:
   - 両方の変更が独立している → 両方を統合（マージ）
   - 同じ箇所の異なる修正 → コードの意図を理解して正しい方を採用、または両方の意図を満たす新しいコードを書く
   - 片方が古い前提に基づいている → 新しい方を優先
5. **Edit ツールでコンフリクトマーカーを除去して正しいコードに修正**
6. 解消したファイルを stage:
   ```bash
   git add <resolved-file>
   ```
7. 全ファイル解消後:
   ```bash
   git rebase --continue
   ```
8. stash pop でコンフリクトした場合も同様に解消する

**重要**: コンフリクト解消は機械的にやらない。必ずコードの意味を理解してから解消すること。

---

## Phase 2: コミット（全モード共通）

### 2-1. 現在の変更を把握

以下を並列で実行:

```bash
git status
git diff
git diff --staged
git log --oneline -10
```

untracked ファイルがあれば中身も確認する。
変更がなければ「コミットする変更がありません」と報告して Phase 3 へ進む。

### 2-2. 変更をグルーピング

以下の観点で変更を意味のある単位に分類する:

- **機能単位**: 同一機能に関する変更をまとめる（ViewModel + View + Service など）
- **関心の分離**: リファクタリング、バグ修正、新機能は混ぜない
- **依存関係**: 共通の型定義変更は、それを使う機能と一緒にコミットする

### 2-3. コミットメッセージを作成

フォーマット:

```
<type>(<scope>): <日本語の要約>
```

- **type**: feat, fix, refactor, chore, docs, style, test
- **scope**: 変更対象のモジュール（pane, sidebar, preview, bookmark, config 等）
- **要約**: 日本語で簡潔に（変更の「何」ではなく「なぜ」を意識）

例:
```
feat(pane): デュアルペイン間のファイルコピーを実装
fix(sidebar): ブックマーク選択時にクラッシュする問題を修正
refactor(config): 設定ファイルの読み込みをCodableベースに移行
```

補足が必要な場合はコミットメッセージ本文にも日本語で書く。

### 2-4. グルーピング結果をユーザーに提示

コミット実行前に、以下の形式でグルーピング結果を提示する:

```
**コミット1**: <type>(<scope>): <subject>
  - file1.swift
  - file2.swift

**コミット2**: <type>(<scope>): <subject>
  - file3.swift
```

### 2-5. コミットを実行

各グループを順番に `git add` + `git commit` する。

- ファイルは個別指定（`git add -A` は使わない）
- コミットメッセージは HEREDOC で渡す
- 末尾に `Co-Authored-By: Codex Opus 4.6 <noreply@anthropic.com>` を付与

### 2-6. 結果を確認

```bash
git status
git log --oneline -N  # N = 今回作成したコミット数 + 数件
```

---

## Phase 3: Push（push / sync モードのみ）

### 3-1. push 前の確認

```bash
git log --oneline origin/$(git branch --show-current)..HEAD
```

push 対象のコミット一覧をユーザーに提示する。

### 3-2. Push を実行

```bash
git push origin $(git branch --show-current)
```

- `--force` は絶対に使わない
- push が rejected された場合（リモートが先に進んでいる場合）は Phase 1 の pull フローに戻って再実行

### 3-3. 他の Mac に同期通知

push 成功後、他の Mac に auto-pull を通知する:

```bash
bash scripts/auto-sync/notify-peers.sh
```

これにより push 元以外の Mac が GitHub から自動 pull する。

---

## 注意事項

- staged 済みの変更がある場合はそれも考慮に含める
- `.env` やクレデンシャル系ファイルはコミットしない（警告を出す）
- 変更がない場合は「コミットする変更がありません」と報告
- `--force` push は絶対にしない
- main/master ブランチへの直接 push 前には警告を出す
- コンフリクト解消が複雑すぎる場合（3ファイル以上 or 大規模な構造変更）はユーザーに確認を取る
