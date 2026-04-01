# Agent Sandbox

AIコーディングエージェント（Claude Code、Codex）をドメインレベルのネットワーク制限付きで実行するためのDev Containerテンプレートです。

**サイドカーmitmproxy**コンテナによるドメインフィルタリングと、エージェントコンテナ内の**iptables**によるプロキシ経由のみのアウトバウンドアクセス制御を使用します。詳細な設計については[docs/architecture.md](docs/architecture.md)を参照してください。

## クイックスタート

### 前提条件

- [VS Code](https://code.visualstudio.com/) と [Dev Containers拡張機能](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)
- [Docker](https://docs.docker.com/get-docker/)

### セットアップ

1. このテンプレートを使用して新しいリポジトリを作成するか、`.devcontainer/`、`.claude/`、`.codex/`、`AGENTS.md` を既存のプロジェクトにコピー

2. VS Codeでプロジェクトを開き、コマンドパレットから **「Dev Containers: Reopen in Container」** を実行

3. コンテナ内での初回セットアップ:
   ```bash
   # Claude Code
   claude login
   gh auth login

   # Codex (初回のみ)
   codex login
   ```

4. Gitリモートを HTTPSに切り替え（SSHはiptablesでブロックされます）:
   ```bash
   git remote set-url origin https://github.com/your-org/your-repo.git
   ```

5. エージェントを実行:
   ```bash
   # Claude Code
   claude --dangerously-skip-permissions

   # Codex (Secure mode — 推奨)
   codex --full-auto
   ```
   Codexは初回実行時にプロジェクトの信頼確認を求めます。承認すると `.codex/config.toml` のサンドボックス設定が適用されます。

## 構成要素

| コンポーネント | 用途 |
|--------------|------|
| **proxy コンテナ** | ドメイン許可リスト付きmitmproxy（`enforcer.py` + `policy.yaml`） |
| **agent コンテナ** | Claude Code、Codex CLI、DinD、zsh、git-delta搭載のnode:20 |
| **init-firewall.sh** | `node` ユーザーをプロキシのみに制限するUID基準のiptables |
| **pre-tool-use.sh** | ファイアウォール/プロキシバイパスコマンドをブロックするPreToolUseフック（Claude Code用） |
| **AGENTS.md** | Codex向けの安全ルール（ソフト制約、`pre-tool-use.sh` と同等のルールを記述） |
| **.codex/config.toml** | Codexサンドボックス設定（`workspace-write` + `network_access=true`） |

## カスタマイズ

### ドメイン許可リスト

`.devcontainer/proxy/policy.yaml` を編集:

```yaml
domains:
  - "*.your-company.com"
  - custom-registry.example.com
```

変更後はコンテナを再ビルドしてください。

### ブランチ保護

`.claude/hooks/pre-tool-use.sh` を編集:

```bash
PROTECTED_BRANCHES="main|develop"
PUSH_PROTECTED_BRANCHES="main|develop|staging"
```

### VS Code 拡張機能

`.devcontainer/devcontainer.json` の `extensions` 配列を編集してください。

### Docker-in-Dockerなしで使用する場合

コンテナ内で `docker` / `docker compose` が不要な場合:

1. `devcontainer.json` から `features` セクションを削除
2. `docker-compose.yml` で `privileged: true` を以下に置き換え:
   ```yaml
   cap_add:
     - NET_ADMIN
     - NET_RAW
   ```
3. `devcontainer.json` の `postStartCommand` を以下に簡略化:
   ```
   "postStartCommand": "test -f /home/node/.gitconfig.host && (grep -q 'gitconfig.host' /home/node/.gitconfig 2>/dev/null || git config --global include.path .gitconfig.host) ; sudo /usr/local/bin/init-firewall.sh"
   ```

### ベースイメージ

Claude CodeとCodexはNode.jsツールのため、エージェントは `node:20` を使用しています。変更する場合:

- `devcontainer.json` の `remoteUser` を更新
- `mounts` と `containerEnv` 内の `/home/node/` パスを更新
- `init-firewall.sh` の `id -u node` を更新

## 動作確認

コンテナ起動後:

```bash
# 許可ドメインへのプロキシ経由アクセス
sudo -u node env HTTP_PROXY=http://proxy:8080 HTTPS_PROXY=http://proxy:8080 \
  curl -s https://api.github.com/zen

# OpenAI APIへの接続テスト
sudo -u node env HTTP_PROXY=http://proxy:8080 HTTPS_PROXY=http://proxy:8080 \
  curl -s https://api.openai.com/v1/models -H "Authorization: Bearer test" \
  -o /dev/null -w "%{http_code}"
# → 401 (認証失敗=接続成功)

# ブロックドメインへのプロキシ経由アクセス
sudo -u node env HTTP_PROXY=http://proxy:8080 HTTPS_PROXY=http://proxy:8080 \
  curl -s https://example.com
# → 403 Forbidden

# iptablesによる直接アクセスのブロック
sudo -u node curl --noproxy '*' https://example.com
# → REJECT

# rootは制限なし（DinD用）
sudo curl https://example.com
# → 成功
```

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
