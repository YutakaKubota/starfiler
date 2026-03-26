---
name: codex
description: Codex MCPに質問を投げて回答を得る。セカンドオピニオンやOpenAIモデルの知見が必要な時に使用。
context: fork
---

# Codex MCP 呼び出し

Codex MCP ツール (`mcp__codex__codex`) を使用して、Codexに質問・相談を行う。

**重要**: このスキルはメイン会話のコンテキストから分離された状態で実行される。過去の会話内容はCodexに渡さない。

## 使用方法

```
/codex "質問内容"
```

例:
```
/codex "NSTableViewでkeyDownをオーバーライドする際のベストプラクティスは？"
/codex "Security-Scoped Bookmarkのライフサイクル管理で注意すべき点は？"
```

## 実行手順

1. `$ARGUMENTS` から質問内容を抽出する
2. **質問内容のみ**をCodexに渡す（会話履歴や背景情報は含めない）
3. 以下のテンプレートでプロンプトを構築:

```
これは単発のリクエストです。過去の会話・保存された履歴・別スレッドの文脈は一切参照しないでください。
以下の質問にのみ回答してください。質問以外の話題に言及しないでください。

## 質問
{ユーザーの質問内容}

## 回答形式
- 簡潔かつ具体的に回答
- コード例がある場合は実行可能な形式で提示
- 不明点があれば質問ではなく最も妥当な解釈で回答
```

4. MCP ツールを呼び出す:

```
mcp__codex__codex(
  prompt: "{構築したプロンプト}",
  sandbox: "read-only"
)
```

5. レスポンスから回答を抽出してユーザーに提示
6. レスポンスの `threadId`（`structuredContent.threadId` 等）を記憶する（フォローアップ用）

## フォローアップ（同一 invocation 内のみ）

Codexの回答に対して深掘りが必要な場合、`codex-reply` で同一セッションを継続できる:

```
mcp__codex__codex_reply(
  prompt: "フォローアップの質問",
  threadId: "{前回のレスポンスから取得したthreadId}"
)
```

- `threadId` が取得できなかった場合はフォローアップをスキップし、単発結果として提示する

## オプション

| パラメータ | 説明 | 例 |
|-----------|------|-----|
| `--cd <path>` | 作業ディレクトリ | `/codex --cd /path/to/project "質問"` |
| `--image <path>` | 画像添付 | `/codex --image screenshot.png "この画面の問題点は？"` |

`$ARGUMENTS` に `--cd <path>` が含まれる場合、MCP 呼び出しの `cwd` パラメータに渡す。

## MCP 接続失敗時のフォールバック

MCP ツール呼び出しがエラー/タイムアウトの場合、旧 CLI 方式にフォールバック:

```bash
codex exec "{構築したプロンプト}" --skip-git-repo-check --sandbox read-only -o /tmp/codex_response.txt 2>&1
```

その後 `/tmp/codex_response.txt` から回答を読み取る。

## 禁止事項

- **メイン会話の履歴をCodexに渡さない**
- **会話のコンテキストや背景説明をプロンプトに含めない**
- 質問内容以外の情報を付加しない
