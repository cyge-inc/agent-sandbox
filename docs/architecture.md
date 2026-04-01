# アーキテクチャ

## 概要

このサンドボックスは、Dev Container内で動作するAIコーディングエージェント（Claude Code、Codex）からのネットワークアクセスを制限するために、**サイドカープロキシ**アーキテクチャを採用しています。

### 参考資料

| ソース | URL |
|--------|-----|
| mattolson/agent-sandbox | https://github.com/mattolson/agent-sandbox |
| Docker Sandbox Network Policies | https://docs.docker.com/ai/sandboxes/network-policies/ |
| Docker and iptables | https://docs.docker.com/engine/network/firewall-iptables/ |
| Claude Code Dev Container | https://github.com/anthropics/claude-code/tree/main/.devcontainer |

## アーキテクチャ図

```
+---------------------------------------------------+
|  Docker Compose ネットワーク                       |
|                                                   |
|  +------------------------+  +------------------+ |
|  |  agent コンテナ         |  |  proxy コンテナ   | |
|  |  (Dev Container)       |  |                  | |
|  |                        |  |  mitmproxy       | |
|  |  Claude Code / Codex   |->|  enforcer.py     | |
|  |  VS Code server        |  |  policy.yaml     | |
|  |                        |  |                  | |
|  |  [iptables]            |  |  cap_drop: ALL   | |
|  |  node: proxy のみ      |  +--------+---------+ |
|  |  root: 制限なし         |           |            |
|  |                        |           v            |
|  |  [DinD]                |      [インターネット]    |
|  |  docker compose 内部   |                        |
|  +------------------------+                        |
+---------------------------------------------------+
```

## 二層防御

### 第1層: プロキシコンテナ（mitmproxy）

プロキシコンテナは、HTTPS CONNECTリクエストをホスト名でフィルタリングするカスタムアドオン（`enforcer.py`）を使用して `mitmdump` を実行します。

- **許可ドメイン**: CONNECTトンネルが確立され、TLSはインターセプトなしでパススルー（MITM不要、CA証明書不要）
- **ブロックドメイン**: CONNECTステージで403 Forbiddenレスポンスを返す（TLSハンドシェイク前）
- **HTTP平文**: Hostヘッダーを同じ許可リストで検証

`tls_clienthello` フックはすべての接続に対して `ignore_connection = True` を設定し、TLSインターセプトが発生しないことを保証します。これにより、CA証明書の配布は不要です。

### 第2層: エージェントコンテナ（iptables）

iptablesルールは `node` ユーザーのみを制限します（`-m owner --uid-owner` によるUID基準のマッチング）:

- `node` ユーザー: TCP経由で `proxy:8080` のみ到達可能。その他すべてのアウトバウンドTCP/UDPはREJECT
- `root` / `dockerd`: 制限なし（DinDによるイメージpullおよびコンテナ実行に必要）
- DNS（UDP/TCP 53）: 全ユーザー許可
- Dockerブリッジ / ホストネットワーク: 全ユーザー許可
- IPv6: ループバックのみ許可、nodeユーザーはそれ以外すべてREJECT

### サイドカー方式を採用する理由

| 懸念事項 | 単一コンテナ | サイドカー |
|---------|------------|----------|
| プロキシの停止 | `sudo kill` で可能 | 別コンテナのため到達不可 |
| ポリシーの改変 | `sudo vi policy.yaml` で可能 | 別ファイルシステムのため到達不可 |
| iptablesの無効化 | `sudo iptables -F` で可能 | 同様に可能（iptablesはagent内）だが、プロキシは引き続き機能 |
| 必要なフックパターン | 多数（kill、nft、unset等） | 最小限 |

### mattolson/agent-sandbox との設計差異

| 項目 | mattolson | 本プロジェクト |
|------|-----------|--------------|
| MITM | あり（CA証明書の配布が必要） | なし（CONNECTホスト名フィルタリングのみ） |
| DinD | なし | あり（docker-in-docker機能） |
| iptables | グローバル OUTPUT DROP | UID基準（nodeのみREJECT） |
| SSH | 完全ブロック | 完全ブロック（HTTPSリモートが必要） |
| HTTP_PROXY | compose `environment` | `remoteEnv`（dockerdへの継承を防止） |

## Codexサンドボックスとの統合

### 問題: Codex内蔵サンドボックスとproxyの競合

Codexはデフォルトで `--unshare-net`（bwrap）またはLandlock `ConnectTcp`/`BindTcp` 制限によりネットワークを分離する。これによりDocker DNS (127.0.0.11) が到達不能になり、sidecar proxy (`proxy:8080`) の名前解決が失敗する。

### 解決: `workspace-write` + `network_access = true`

`.codex/config.toml` でサンドボックスモードを設定:

```toml
sandbox_mode = "workspace-write"

[sandbox_workspace_write]
network_access = true
```

- **ファイルシステム**: bwrap（Bubblewrap）によるハード制約。ワークスペースとTMPDIRのみ書き込み可能、`.git`/`.codex` は読み取り専用
- **ネットワーク**: `network_access = true` によりネットワーク分離を無効化。Docker DNSが到達可能になり、proxy経由の通信が成立。ネットワーク制御はsidecar proxy + iptablesに委譲
- **sudo**: bwrapは `PR_SET_NO_NEW_PRIVS` を設定。Codexが生成・実行するシェルコマンド内で `sudo` が使えない（Secure modeのみ）

### 実行モード

| モード | コマンド | FS保護 | sudoブロック | ネットワーク | 承認 |
|--------|---------|--------|-------------|-------------|------|
| **Secure** (推奨) | `codex --full-auto` | bwrap (ハード) | no_new_privs (ハード) | proxy+iptables (ハード) | on-request |
| **Degraded** | `codex --sandbox danger-full-access` | なし | なし | proxy+iptables (設定済みだが `sudo` でバイパス可能) | on-request |
| **Unsafe** | `codex --dangerously-bypass-approvals-and-sandbox` | なし | なし | Degradedと同等 | なし |

Degraded/Unsafe modeでは `node ALL=(ALL) NOPASSWD:ALL` により、`sudo iptables -F` や `docker run --net=host` でネットワーク制御をバイパスできる。これらのモードを使用する場合は、sudoers制限の適用を推奨する（下記「カスタマイズポイント」参照）。

### Claude Code vs Codex

| 防御層 | Claude Code | Codex (Secure mode) |
|--------|------------|---------------------|
| ネットワーク | proxy + iptables | proxy + iptables (同等) |
| ファイルシステム | 制限なし | bwrap workspace-write (ハード) |
| ツール制御 | PreToolUseフック (ハード) | AGENTS.md (ソフト、助言的) |
| sudo | フックでブロック (パターンマッチ) | no_new_privs (カーネルレベル) |
| ブランチ保護 | フックでブロック (ハード) | AGENTS.md (ソフト) |

### AGENTS.md

`AGENTS.md` はCodex向けのソフト制約ファイル。Claude Codeの `pre-tool-use.sh` と同等のルールをLLMへの指示として記述する。

**制限事項**:
- AGENTS.mdはプロンプトインジェクション等で無視される可能性がある
- Codexは `AGENTS.md` を階層的に解釈する。サブディレクトリの `AGENTS.md` がルートのルールを上書きするリスクがある

## セキュリティモデル

### 脅威モデル

**防御対象**: AIコーディングエージェントが通常操作中に意図しないアウトバウンド接続を行うこと（例: 外部APIを呼び出すテストの実行、予期しないパッケージのインストール）

**防御対象外**: 意図的なバイパス攻撃（プロンプトインジェクションによる意図的な迂回）

### 既知の制限事項

| リスク | 理由 |
|-------|------|
| DNSトンネリング | DNS（UDP 53）を許可する必要がある |
| 許可ドメイン経由のデータ流出 | GitHub Gistへのアップロード、npm publishなど |
| `--privileged` によるコンテナエスケープ | DinDに必要 |
| DinD子コンテナのトラフィック | FORWARDチェーンは未制限（Phase 1） |
| `sudo iptables -F` によるルールクリア | iptablesはagentコンテナ内にあり、PreToolUse Hookで緩和 |
| `sudo bash -c "iptables -F"` | 間接実行はフックのパターンマッチングをバイパスする |
| Codex AGENTS.mdルールの無視 | AGENTS.mdは助言的であり強制されない |
| Codex AGENTS.md階層上書き | サブディレクトリのAGENTS.mdがルートのルールを上書きする可能性 |
| Codexプロセスのbwrap外動作 | Codex本体のAPI通信はbwrap外。iptablesで制御 |
| Codex HTTPクライアントのproxy対応 | 要実機検証。proxy未対応の場合iptablesでREJECTされる |
| Degraded/Unsafe modeでのsudoバイパス | bwrap無効時はno_new_privsが消失し、sudoでiptables/proxyバイパス可能 |

## カスタマイズポイント

### ドメイン許可リスト

`.devcontainer/proxy/policy.yaml` を編集して、許可ドメインの追加・削除ができます:

```yaml
domains:
  - "*.your-company.com"
  - custom-registry.example.com
```

ワイルドカード `*.example.com` は `sub.example.com` にマッチしますが、`example.com` 自体にはマッチしません。必要に応じて両方追加してください。

### ブランチ保護

`.claude/hooks/pre-tool-use.sh` を編集して保護ブランチを変更できます:

```bash
PROTECTED_BRANCHES="main|develop"
PUSH_PROTECTED_BRANCHES="main|develop|staging"
```

### sudoers制限（Degraded/Unsafe mode向け強化策）

Codex Degraded/Unsafe modeでは `sudo` によるiptablesバイパスが可能。DinDが不要なユースケースでは、sudoersを制限することでこのリスクを軽減できる:

```bash
# Dockerfile内で以下に置き換え:
# node ALL=(ALL) NOPASSWD:ALL
node ALL=(ALL) NOPASSWD: /usr/local/bin/init-firewall.sh, /usr/local/share/docker-init.sh, /usr/bin/docker
```

**注意**: この制限を適用するとDinD内での任意パッケージインストール等（`sudo apt-get install`）が使えなくなる。

### ベースイメージ

agentのDockerfileは、Claude CodeとCodexがNode.jsベースのツールであるため `node:20` を使用しています。ベースイメージを変更する場合:

1. `devcontainer.json` の `remoteUser` を更新
2. `devcontainer.json` のマウントおよびcontainerEnv内のすべての `/home/node/` パスを更新
3. `init-firewall.sh` の `id -u node` を新しいユーザー名に合わせて更新
4. `iptables` と `iproute2` がインストールされていることを確認
