# Proxmox Container Tools

Proxmox VE用のコンテナ管理ユーティリティツール集です。

## ツール一覧

### pct_cp.sh

Proxmoxコンテナからホストへのファイルやディレクトリのコピーを行うツールです。
`cp`コマンドと同様の使い方で、コンテナ内のファイルやディレクトリを安全にコピーできます。

#### 特徴

- コンテナの実行状態に関わらずコピー可能
- ディレクトリの再帰的コピーをサポート
- ACLやシンボリックリンクの適切な処理
- 特殊権限の管理
- 安全なバックアップと復元機能

#### 使用方法

```bash
./pct_cp.sh [-f] <CTID> <コンテナ内のパス> <ホスト上の出力先パス>

オプション:
  -f    確認プロンプトをスキップし、既存ファイルを上書き
```

#### 例

1. ディレクトリごとコピー:
```bash
./pct_cp.sh 100 /var/www/html /backup/container100/
# 結果: /backup/container100/html/ が作成される
```

2. ディレクトリの中身のみコピー:
```bash
./pct_cp.sh 100 /var/www/html/ /backup/container100/
# 結果: /backup/container100/ 直下にファイルがコピーされる
```

3. 単一ファイルのコピー:
```bash
./pct_cp.sh 100 /etc/nginx/nginx.conf /backup/container100/
# 結果: /backup/container100/nginx.conf が作成される
```

## インストール

1. リポジトリをクローン:
```bash
git clone https://github.com/yourusername/proxmox-container-tools.git /opt/proxmox-container-tools
```

2. スクリプトに実行権限を付与:
```bash
chmod +x /opt/proxmox-container-tools/pct_cp.sh
```

## 要件

- Proxmox VE 7.0以上
- bash
- tar
- rsync（オプション、ただし推奨）
- ACLツール（オプション: getfacl, setfacl）

## ライセンス

このプロジェクトは[MIT License](LICENSE)の下で公開されています。

## 貢献

バグ報告や機能要望は、GitHubのIssueでお願いします。
プルリクエストも歓迎です。 