---
name: codex-impl
description: Codexに実装作業を依頼する。ファイルの変更を含む作業に使用。
context: fork
---

# Codex 実装

Codex MCP ツールを使用して実装作業を実行する。Codex がファイルの読み書きを行える。

## 使用方法

```
/codex-impl "実装内容の説明"
/codex-impl --cd /path/to/project "テストを追加して"
```

## 実行手順

### 1. `$ARGUMENTS` から指示内容を抽出

`--cd <path>` がある場合は `cwd` パラメータに分離する。デフォルト `cwd` は `/Users/workspace/NilOne/starfiler/starfiler-app`。

### 2. プロンプトを構築

```
これは単発の実装リクエストです。過去の会話を参照しないでください。

## プロジェクト概要
macOS 15+専用デュアルペインファイラー「starfiler」の実装です。
- 技術スタック: Swift + AppKit（必要に応じてSwiftUI併用）
- アーキテクチャ: MVVM + Service Layer
- ViewModelは@Observable、AppKit非依存
- Swift Concurrency (async/await, actor) 使用
- サンドボックス前提設計（Security-Scoped Bookmarks）

実装プランは docs/implementation-plan.md、レビュー結果は docs/plan-review.md を参照してください。

## 指示
{ユーザーの指示内容}

## 制約
- 既存のコード規約・パターンに従う
- 最小限の変更で目的を達成する
- ViewModelにAppKitをimportしない
- Swift 6のSendable厳格チェックを意識する
- 変更したファイルの一覧を最後に記載する
```

### 3. MCP ツールを呼び出す

```
mcp__codex__codex(
  prompt: "{構築したプロンプト}",
  sandbox: "workspace-write",
  approval-policy: "on-failure",
  cwd: "{cwdパス}"
)
```

### 4. 結果を確認

Codexの実行結果を確認し、変更されたファイルの一覧をユーザーに提示する。

### 5. フォローアップ（任意）

修正や追加作業が必要な場合:

```
mcp__codex__codex_reply(
  prompt: "追加の指示",
  threadId: "{前回のthreadId}"
)
```

## MCP 接続失敗時のフォールバック

```bash
codex exec "{構築したプロンプト}" --skip-git-repo-check --sandbox workspace-write -o /tmp/codex_response.txt 2>&1
```

その後 `/tmp/codex_response.txt` から回答を読み取る。

## 注意事項

- `sandbox: "workspace-write"` — Codex がプロジェクト内のファイルを変更可能
- `approval-policy: "on-failure"` — 失敗時に自動リトライ、危険な操作は確認
- 実行後は `git diff` で変更内容を確認することを推奨
- メイン会話の履歴をCodexに渡さない
