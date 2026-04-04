# Agent Sandbox — Dev Container

AIコーディングエージェント（Claude Code、Codex）をドメインレベルのネットワーク制限付きで実行するためのDev Container設定です。

サイドカーmitmproxyによるドメインフィルタリングと、エージェントコンテナ内のiptablesによるプロキシ経由のみのアウトバウンドアクセス制御を組み合わせています。

## 構成ファイル

```
.devcontainer/
├── devcontainer.json      # Dev Container設定
├── docker-compose.yml     # agent + proxy の2コンテナ構成
├── Dockerfile             # agentコンテナのビルド定義
├── init-firewall.sh       # UID基準のiptablesルール
├── proxy/
│   ├── Dockerfile         # mitmproxyコンテナ
│   ├── enforcer.py        # ドメインフィルタリングアドオン
│   └── policy.yaml        # ドメイン許可リスト
└── README.md              # このファイル
```

併せて以下のファイルもプロジェクトルートに配置してください:

| ファイル | 用途 |
|---------|------|
| `.claude/hooks/pre-tool-use.sh` | Claude Code用 — ファイアウォール/プロキシバイパスコマンドをブロックするPreToolUseフック |
| `.codex/config.toml` | Codex用 — `workspace-write` サンドボックス設定 |
| `AGENTS.md` | Codex用 — 安全ルール（ソフト制約） |

## セットアップ

1. VS Codeでプロジェクトを開き、コマンドパレットから **「Dev Containers: Reopen in Container」** を実行

2. コンテナ内での初回セットアップ:
   ```bash
   # Claude Code
   claude login
   gh auth login

   # Codex (初回のみ)
   codex login
   ```

3. Gitリモートを HTTPSに切り替え（SSHはiptablesでブロックされます）:
   ```bash
   git remote set-url origin https://github.com/your-org/your-repo.git
   ```

4. エージェントを実行:
   ```bash
   # Claude Code
   claude --dangerously-skip-permissions

   # Codex (Secure mode — 推奨)
   codex --full-auto
   ```

## カスタマイズ

### ドメイン許可リスト

`.devcontainer/proxy/policy.yaml` を編集:

```yaml
domains:
  - "*.your-company.com"
  - custom-registry.example.com
```

ワイルドカード `*.example.com` は `sub.example.com` にマッチしますが、`example.com` 自体にはマッチしません。変更後はコンテナを再ビルドしてください。

### ブランチ保護

`.claude/hooks/pre-tool-use.sh` を編集:

```bash
PROTECTED_BRANCHES="main|develop"
PUSH_PROTECTED_BRANCHES="main|develop|staging"
```

### VS Code 拡張機能

`devcontainer.json` の `extensions` 配列を編集してください。

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
- マウントと `containerEnv` 内の `/home/node/` パスを更新
- `init-firewall.sh` の `id -u node` を更新
- `iptables` と `iproute2` がインストールされていることを確認

## 動作確認

コンテナ起動後:

```bash
# 許可ドメインへのプロキシ経由アクセス
sudo -u node env HTTP_PROXY=http://proxy:8080 HTTPS_PROXY=http://proxy:8080 \
  curl -s https://api.github.com/zen

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

### 仕組み

1. **プロキシコンテナ（mitmproxy）** — HTTPS CONNECTリクエストをホスト名でフィルタリング。TLSはインターセプトせずパススルー（CA証明書不要）。ブロック時は403を返す
2. **iptables（agentコンテナ内）** — `node` ユーザーのアウトバウンドをプロキシ経由のみに制限。rootは制限なし（DinD用）
3. **サイドカー分離** — プロキシが別コンテナのため、agentコンテナ内の `sudo kill` や `sudo vi policy.yaml` では停止・改変できない

### Claude Code vs Codex

| 防御層 | Claude Code | Codex (Secure mode) |
|--------|------------|---------------------|
| ネットワーク | proxy + iptables (ハード) | proxy + iptables (ハード) |
| ファイルシステム | 制限なし | bwrap: workspace-write (ハード) |
| sudo | PreToolUseフックでブロック (ハード) | `no_new_privs` でブロック (ハード) |
| ツール制御 | PreToolUseフック (ハード) | AGENTS.md (ソフト) |
