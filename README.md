# Agent Sandbox

AIコーディングエージェント（Claude Code、Codex）をドメインレベルのネットワーク制限付きで実行するためのDev Containerテンプレートです。

**サイドカーmitmproxy**コンテナによるドメインフィルタリングと、エージェントコンテナ内の**iptables**によるプロキシ経由のみのアウトバウンドアクセス制御を使用します。詳細な設計については[docs/architecture.md](docs/architecture.md)を参照してください。

## クイックスタート

### 前提条件

- [VS Code](https://code.visualstudio.com/) と [Dev Containers拡張機能](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)
- [Docker](https://docs.docker.com/get-docker/)

### 使い方

**A) テンプレートとして使用**: このテンプレートから新しいリポジトリを作成

**B) 既存プロジェクトに組み込み**: 以下のファイルをコピー
- `.devcontainer/` — Dev Container設定一式（セットアップ手順は [.devcontainer/README.md](.devcontainer/README.md) を参照）
- `.claude/` — Claude Code用フック設定
- `.codex/` — Codexサンドボックス設定
- `AGENTS.md` — Codex向け安全ルール

## 構成要素

| コンポーネント | 用途 |
|--------------|------|
| **proxy コンテナ** | ドメイン許可リスト付きmitmproxy（`enforcer.py` + `policy.yaml`） |
| **agent コンテナ** | Claude Code、Codex CLI、DinD、zsh、git-delta搭載のnode:20 |
| **init-firewall.sh** | `node` ユーザーをプロキシのみに制限するUID基準のiptables |
| **pre-tool-use.sh** | ファイアウォール/プロキシバイパスコマンドをブロックするPreToolUseフック（Claude Code用） |
| **AGENTS.md** | Codex向けの安全ルール（ソフト制約、`pre-tool-use.sh` と同等のルールを記述） |
| **.codex/config.toml** | Codexサンドボックス設定（`workspace-write` + `network_access=true`） |

## カスタマイズ・動作確認

セットアップ手順、カスタマイズ方法、動作確認については [.devcontainer/README.md](.devcontainer/README.md) を参照してください。

## セキュリティモデル

これは**ベストエフォート**のセーフティネットです。AIエージェントが通常操作中に意図しないアウトバウンド接続を行うことを防止します。意図的なバイパス攻撃に対する防御は提供しません。

### Claude Code vs Codex

| 防御層 | Claude Code | Codex (Secure mode) |
|--------|------------|---------------------|
| ネットワーク | proxy + iptables (ハード) | proxy + iptables (ハード) |
| ファイルシステム | 制限なし | bwrap: workspace-write, `.git`/`.codex` 読み取り専用 (ハード) |
| sudo | PreToolUseフックでブロック (ハード) | `no_new_privs` でブロック (ハード) |
| ツール制御 | PreToolUseフック (ハード) | AGENTS.md (ソフト) |

### Codex実行モード

| モード | コマンド | セキュリティ |
|--------|---------|-------------|
| **Secure** (推奨) | `codex --full-auto` | bwrap + proxy + iptables。sudoブロック |
| **Degraded** | `codex --sandbox danger-full-access` | proxy + iptables のみ (sudoでバイパス可能) |
| **Unsafe** | `codex --dangerously-bypass-approvals-and-sandbox` | Degradedと同等 + 承認プロンプト無効 |

脅威モデルと既知の制限事項の全容については[docs/architecture.md](docs/architecture.md)を参照してください。

## 参考資料

- [mattolson/agent-sandbox](https://github.com/mattolson/agent-sandbox) - mitmproxy + iptablesサイドカーアーキテクチャ
- [Docker Sandbox Network Policies](https://docs.docker.com/ai/sandboxes/network-policies/) - DockerのAIサンドボックスネットワーキング
- [Claude Code Dev Container](https://github.com/anthropics/claude-code/tree/main/.devcontainer) - 公式IPベースのリファレンス
