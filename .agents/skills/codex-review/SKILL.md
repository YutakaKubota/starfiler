---
name: codex-review
description: Codexにコードレビューを依頼する。プランレビュー、差分レビュー、設計レビューに使用。
context: fork
---

# Codex コードレビュー

Codex MCP ツールを使用してコードレビューを実行する。

## 使用方法

```
/codex-review "レビュー内容やコードの説明"
/codex-review --diff
/codex-review --staged
/codex-review --file path/to/file.swift
```

## 実行手順

### 1. レビュー対象を特定

`$ARGUMENTS` を解析:

| 引数 | 動作 |
|------|------|
| `--diff` | Bash で `git diff` を実行し、その出力をレビュー対象にする |
| `--staged` | Bash で `git diff --staged` を実行し、その出力をレビュー対象にする |
| `--file <path>` | Read ツールでファイル内容を取得し、レビュー対象にする |
| テキストのみ | `$ARGUMENTS` のテキスト自体をレビュー対象にする（プラン等） |

### 2. プロンプトを構築

```
これは単発のコードレビューリクエストです。過去の会話を参照しないでください。

## プロジェクト概要
macOS 15+専用デュアルペインファイラー「starfiler」のSwift/AppKitプロジェクトです。
- アーキテクチャ: MVVM + Service Layer
- ViewModelは@Observable、AppKit非依存
- Swift Concurrency (async/await, actor) 使用
- サンドボックス前提設計

## レビュー対象
{取得したコンテンツ}

## レビュー基準
以下の観点で問題点を指摘してください:
- Critical（重大）: バグ、セキュリティ問題、データ損失リスク、サンドボックス違反
- Major（重要）: 設計上の問題、パフォーマンス問題、保守性の低下、Swift Concurrency不正使用
- Minor（軽微）: コードスタイル、命名、ドキュメント不足

特に以下を重点的にチェック:
- ViewModelがAppKitに依存していないか
- Security-Scoped Bookmarkのライフサイクル管理
- @MainActor指定の適切性
- NSTableView/NSSplitViewの正しい使用法
- メモリリーク（循環参照）の可能性

## 回答形式
各カテゴリごとに箇条書きで指摘。問題がなければ「問題なし」と明記。
最後に総合評価（LGTM / 要修正 / 要大幅修正）を記載。
```

### 3. MCP ツールを呼び出す

```
mcp__codex__codex(
  prompt: "{構築したプロンプト}",
  sandbox: "read-only"
)
```

### 4. レビュー結果をユーザーに提示

レスポンスの `threadId` を記憶する。

### 5. フォローアップ（任意）

特定の指摘について深掘りが必要な場合:

```
mcp__codex__codex_reply(
  prompt: "この指摘について具体的な修正案を提示して",
  threadId: "{前回のthreadId}"
)
```

## MCP 接続失敗時のフォールバック

```bash
codex exec "{構築したプロンプト}" --skip-git-repo-check --sandbox read-only -o /tmp/codex_response.txt 2>&1
```

その後 `/tmp/codex_response.txt` から回答を読み取る。

## 注意事項

- `sandbox: "read-only"` 固定（レビューはファイル変更不要）
- 大きな diff はトークン制限に注意。ファイル数が多い場合は分割を検討
- メイン会話の履歴をCodexに渡さない
