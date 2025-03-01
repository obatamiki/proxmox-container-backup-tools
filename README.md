# Proxmox Container Tools

Proxmox VE用のコンテナ管理ユーティリティツール集です。

## ツール一覧

### pct_pull.sh

Proxmoxコンテナからホストへのファイルやディレクトリの取得を行うツールです。
標準の`pct pull`コマンドを拡張し、より安全で使いやすい機能を提供します。

#### 特徴

- コンテナの実行状態に関わらずファイル取得が可能
- ディレクトリの再帰的コピーをサポート
- ACLやシンボリックリンクの適切な処理
- 特殊権限の管理
- 安全なバックアップと復元機能
- 既存ファイルの上書き確認
- ディレクトリ内容の詳細なコピー制御

#### 使用方法

```bash
./pct_pull.sh [-f] <CTID> <コンテナ内のパス> <ホスト上の出力先パス>

オプション:
  -f    確認プロンプトをスキップし、既存ファイルを上書き
```

#### 例

1. ディレクトリごと取得:
```bash
./pct_pull.sh 100 /var/www/html /backup/container100/
# 結果: /backup/container100/html/ が作成される
```

2. ディレクトリの中身のみ取得:
```bash
./pct_pull.sh 100 /var/www/html/ /backup/container100/
# 結果: /backup/container100/ 直下にファイルがコピーされる
```

3. 単一ファイルの取得:
```bash
./pct_pull.sh 100 /etc/nginx/nginx.conf /backup/container100/
# 結果: /backup/container100/nginx.conf が作成される
```

## インストール

1. リポジトリをクローン:
```bash
git clone https://github.com/yourusername/proxmox-container-tools.git /opt/proxmox-container-tools
```

2. スクリプトに実行権限を付与:
```bash
chmod +x /opt/proxmox-container-tools/pct_pull.sh
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