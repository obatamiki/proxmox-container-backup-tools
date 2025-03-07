# Proxmox Container Backup Tools

Proxmox VE（Virtual Environment）用のコンテナバックアップ・ファイル管理ユーティリティツール集です。
LXC（Linux Containers）のファイル管理やバックアップを支援する機能を提供します。

## ツール一覧

### pct-pull.sh

Proxmoxコンテナ（LXC）からホストへのファイルやディレクトリの取得を行うツールです。
標準の`pct`（Proxmox Container Toolkit）コマンドを拡張し、より安全で使いやすい機能を提供します。
コンテナからのデータ取得やバックアップ作成に最適です。

#### 特徴

- コンテナの実行状態に関わらずファイル取得が可能（実行中/停止中どちらでも対応）
- ディレクトリの再帰的コピー（recursive copy）をサポート
- ACL（Access Control List）の保持と適切な処理
- シンボリックリンクの安全な処理
- 特殊権限（setuid/setgid）の管理
- コピー失敗時のロールバック機能
- 既存ファイルの上書き確認
- ディレクトリ内容の詳細なコピー制御

#### ユースケース

- コンテナのデータバックアップ
- 設定ファイルの抽出と管理
- コンテナ間のデータ移行
- トラブルシューティング時のログファイル取得
- Webサイトデータの取得

#### 使用方法

```bash
pct-pull [-f] <CTID> <コンテナ内のパス> <ホスト上の出力先パス>

引数:
  CTID                Proxmox VE上のコンテナID（100-999999の範囲の数値）
  コンテナ内のパス    取得したいファイルやディレクトリのコンテナ内でのパス
  ホスト上の出力先パス  ホスト側での保存先パス

オプション:
  -f    確認プロンプトをスキップし、既存ファイルを上書き

終了コード:
  0     正常終了
  1     一般的なエラー（引数エラー、ファイルアクセスエラーなど）
  2     コンテナ関連のエラー（存在しない、アクセス不可など）
```

注: CTIDはProxmox VEで各コンテナに割り当てられる一意の識別番号です。`pct list`コマンドで現在のCTID一覧を確認できます。

#### プログラムからの利用

このスクリプトは他のプログラムやスクリプトから呼び出して使用することができます：

- 非対話モード: `-f`オプションを使用することで、確認プロンプトなしで実行できます
- 終了コードによるエラー判定: スクリプトの実行結果は終了コードで判断できます
- 標準出力/標準エラー出力:
  - 標準出力: 処理の進捗状況や成功メッセージ
  - 標準エラー出力: エラーメッセージやワーニング

使用例（シェルスクリプトの場合）:
```bash
if pct-pull -f 100 /etc/nginx/nginx.conf /backup/container100/; then
    echo "バックアップ成功"
else
    echo "バックアップ失敗"
fi
```

注意点:
- 大量のファイルを扱う場合は、十分なディスク容量とメモリを確保してください
- 実行には root 権限が必要です
- 同時実行時は一時ファイル名が重複しないよう考慮されています

#### 例

1. ディレクトリごと取得:
```bash
pct-pull 100 /var/www/html /backup/container100/
# 結果: /backup/container100/html/ が作成される
```

2. ディレクトリの中身のみ取得:
```bash
pct-pull 100 /var/www/html/ /backup/container100/
# 結果: /backup/container100/ 直下にファイルがコピーされる
```

3. 単一ファイルの取得:
```bash
pct-pull 100 /etc/nginx/nginx.conf /backup/container100/
# 結果: /backup/container100/nginx.conf が作成される
```

## インストール

1. リポジトリをクローン:
```bash
cd /opt
git clone https://github.com/obatamiki/proxmox-container-backup-tools.git
```

2. 実行権限を付与:
```bash
chmod +x /opt/proxmox-container-backup-tools/pct-pull.sh
```

3. シンボリックリンクを作成:
```bash
ln -s /opt/proxmox-container-backup-tools/pct-pull.sh /usr/local/bin/pct-pull
```

これにより、`pct-pull`コマンドとして実行できるようになります。

## アンインストール

1. シンボリックリンクを削除:
```bash
rm /usr/local/bin/pct-pull
```

2. リポジトリを削除:
```bash
rm -rf /opt/proxmox-container-backup-tools
```

注: 設定ファイルやバックアップは作成されないため、上記の手順で完全に削除されます。

## 要件

### 動作環境
- Proxmox VE（6.0以上を推奨）
- ファイルシステムの互換性：
  - ext4, xfs, zfs など、主要なLinuxファイルシステムで動作します
  - ZFSを使用している場合でも、ACLやパーミッションは正しく保持されます
  - ファイルシステムの種類に依存する特別な機能は使用していないため、基本的にすべてのファイルシステムで動作します

### ホスト側で必要なパッケージ
- ACLツール（getfacl, setfacl）
  ```bash
  # Debian/Ubuntu系の場合
  apt install acl
  ```
  ※ ACLツールがない場合でもスクリプトは動作しますが、コンテナからコピーしたファイルのACL情報が保持されません。

注: その他の必要なコンポーネント（bash, tar, rsync）はProxmox VEに標準で含まれています。

## 関連情報

- [Proxmox VE Documentation](https://pve.proxmox.com/pve-docs/)
- [Linux Containers - LXC](https://linuxcontainers.org/)
- [pct コマンドリファレンス](https://pve.proxmox.com/pve-docs/pct.1.html)

## ライセンス

このプロジェクトは[MIT License](LICENSE)の下で公開されています。

## 貢献

バグ報告や機能要望は、GitHubのIssueでお願いします。
プルリクエストも歓迎です。

## キーワード

### 一般
- Proxmox VE (Proxmox Virtual Environment)
- LXC (Linux Containers)
- コンテナ管理 / Container Management
- バックアップ / Backup
- ファイル転送 / File Transfer
- データ移行 / Data Migration

### 技術用語
- ACL (Access Control List) / アクセス制御リスト
- 再帰的コピー / Recursive Copy
- シンボリックリンク / Symbolic Links
- 権限管理 / Permission Management
- setuid/setgid
- pct pull
- rsync

### ユースケース
- コンテナバックアップ / Container Backup
- ファイル抽出 / File Extraction
- 設定ファイル管理 / Configuration Management
- データ復旧 / Data Recovery
- トラブルシューティング / Troubleshooting
- Webサイトデータ取得 / Website Data Retrieval
- コンテナ間データ移行 / Inter-Container Data Migration

### 関連ツール・技術
- Proxmox Backup Server
- Proxmox Container Toolkit
- pct（Proxmox Container Tools）
- LXC Tools
- Linux File Permissions 