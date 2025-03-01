#!/bin/bash

# エラー時即時終了とパイプのエラーチェックを有効化
set -eo pipefail

# デフォルトのumask設定
DEFAULT_UMASK=022
ORIGINAL_UMASK=$(umask)

# デフォルトオプション
FORCE=false          # 強制上書きモード

# グローバル変数の定義
# これらの変数は関数間で状態を共有するために使用されます
declare HOST_TEMP_DIR=""      # 一時ディレクトリのパス
declare TEMP_TAR=""          # 一時tarファイルのパス
declare BACKUP_DIR=""        # バックアップディレクトリのパス
declare RESTORE_TARGET=""    # バックアップ復元先のパス
declare ACL_TEMP_FILE=""     # ACL情報保存用の一時ファイル

# 使用方法を表示する関数
show_usage() {
    echo "使用方法: $0 [-f] <CTID> <コンテナ内のパス> <ホスト上の出力先パス>"
    echo "説明: Proxmoxコンテナからホストへファイルやディレクトリを取得します。"
    echo "      標準のpct pullコマンドを拡張し、より安全で使いやすい機能を提供します。"
    echo
    echo "オプション:"
    echo "  -f    確認プロンプトをスキップし、既存ファイルを上書き"
    echo "  末尾のスラッシュ: コンテナ内のパスの末尾にスラッシュを付けると、"
    echo "                     ディレクトリの中身のみを取得します。"
    echo
    echo "例:"
    echo "  # ディレクトリごと取得（/backup/container100/html/ が作成される）"
    echo "  $0 100 /var/www/html /backup/container100/"
    echo
    echo "  # ディレクトリの中身のみ取得（/backup/container100/ 直下にファイルが展開される）"
    echo "  $0 100 /var/www/html/ /backup/container100/"
    echo
    echo "  # 単一ファイルの取得"
    echo "  $0 100 /etc/nginx/nginx.conf /backup/container100/"
    exit 1
}

# 引数の解析
while getopts "fh" opt; do
    case $opt in
        f)
            FORCE=true
            ;;
        h)
            show_usage
            ;;
        \?)
            show_usage
            ;;
    esac
done
shift $((OPTIND-1))

# 引数の数を確認（オプション処理後の残りの引数）
if [ $# -ne 3 ]; then
    show_usage
fi

CTID=$1
CONTAINER_PATH=$2
HOST_PATH=$3

# パスの検証
if [[ "$CONTAINER_PATH" =~ [[:space:]] ]] || [[ "$HOST_PATH" =~ [[:space:]] ]]; then
    echo "エラー: パスに空白を含めることはできません。"
    exit 1
fi

# コンテナの存在確認
if [ ! -d "/etc/pve/lxc/$CTID" ]; then
    echo "エラー: コンテナ $CTID が存在しません。"
    exit 1
fi

# 入力パスの末尾スラッシュを確認（cp -rの挙動に合わせる）
COPY_CONTENTS_ONLY=false
if [[ "$CONTAINER_PATH" =~ /$ ]]; then
    COPY_CONTENTS_ONLY=true
fi

# 末尾のスラッシュを削除
CONTAINER_PATH=${CONTAINER_PATH%/}
HOST_PATH=${HOST_PATH%/}

# ログ出力関数
log_message() {
    local level="$1"
    local message="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message"
}

# クリーンアップ関数
cleanup() {
    local exit_code=$?
    log_message "INFO" "クリーンアップを実行中..."

    # 一時ディレクトリの削除
    if [ -n "$HOST_TEMP_DIR" ] && [ -d "$HOST_TEMP_DIR" ]; then
        rm -rf "$HOST_TEMP_DIR"
        log_message "INFO" "一時ディレクトリを削除しました: $HOST_TEMP_DIR"
    fi

    # コンテナ内の一時ファイルの削除（コンテナが実行中の場合のみ）
    if [ -n "$CTID" ] && [ -n "$TEMP_TAR" ]; then
        if pct status "$CTID" | grep -q "status: running"; then
            if ! pct exec "$CTID" -- rm -f "$TEMP_TAR" 2>/dev/null; then
                log_message "WARN" "コンテナ内の一時ファイルの削除に失敗しました: $TEMP_TAR"
            else
                log_message "INFO" "コンテナ内の一時ファイルを削除しました: $TEMP_TAR"
            fi
        fi
    fi

    # 処理が失敗した場合のバックアップ復元
    if [ $exit_code -ne 0 ] && [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
        log_message "WARN" "エラーが発生したため、バックアップから復元を試みます..."
        restore_backup "$BACKUP_DIR" "$RESTORE_TARGET"
    fi

    # umaskを元に戻す
    umask "$ORIGINAL_UMASK"

    exit "$exit_code"
}

# クリーンアップ関数を登録
trap cleanup EXIT

# バックアップ関連の関数
create_backup() {
    local target="$1"
    local backup_dir
    
    if [ ! -e "$target" ]; then
        return
    fi

    # バックアップディレクトリの作成（タイムスタンプとランダム文字列で一意性を確保）
    backup_dir="$(dirname "$target")/.backup_$(date +%Y%m%d_%H%M%S)_$RANDOM"
    if ! mkdir -p "$backup_dir"; then
        echo "エラー: バックアップディレクトリの作成に失敗しました: $backup_dir"
        exit 1
    fi

    # バックアップの作成
    if ! cp -a "$target" "$backup_dir/"; then
        echo "エラー: バックアップの作成に失敗しました"
        rm -rf "$backup_dir"
        exit 1
    fi

    echo "バックアップを作成しました: $backup_dir"
    BACKUP_DIR="$backup_dir"
    RESTORE_TARGET="$target"
    echo "$backup_dir"
}

restore_backup() {
    local backup_dir="$1"
    local target="$2"

    if [ ! -d "$backup_dir" ]; then
        echo "警告: バックアップディレクトリが見つかりません: $backup_dir"
        return 1
    fi

    echo "バックアップから復元中: $backup_dir -> $target"
    
    # ターゲットの削除
    if [ -e "$target" ]; then
        if ! rm -rf "$target"; then
            echo "エラー: 既存のターゲットの削除に失敗しました: $target"
            return 1
        fi
    fi

    # バックアップから復元
    if ! mv "$backup_dir"/* "$(dirname "$target")/"; then
        echo "エラー: バックアップからの復元に失敗しました"
        return 1
    fi

    # バックアップディレクトリの削除
    rm -rf "$backup_dir"
    echo "バックアップからの復元が完了しました"
    return 0
}

# 安全性チェック関数
check_target_exists() {
    local target="$1"
    if [ -e "$target" ]; then
        echo "警告: $target は既に存在します。"
        read -p "上書きしますか？ (y/N): " response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            echo "取得を中止します。"
            exit 1
        fi
        # バックアップを作成
        BACKUP_DIR=$(create_backup "$target")
    fi
}

# ファイルタイプとシンボリックリンクの情報を一度に取得
get_file_info() {
    local path="$1"
    local result

    if [ -n "$CTID" ] && pct status "$CTID" | grep -q "status: running"; then
        # コンテナ実行中の場合
        result=$(pct exec "$CTID" -- find "$path" -mindepth 0 -maxdepth 0 -printf '%y\n')
        case "$result" in
            d) echo "directory" ;;
            l) echo "symlink" ;;
            f) echo "file" ;;
            *) echo "unknown" ;;
        esac
    else
        # コンテナ停止中の場合
        if [ -L "$path" ]; then
            echo "symlink"
        elif [ -d "$path" ]; then
            echo "directory"
        elif [ -f "$path" ]; then
            echo "file"
        else
            echo "unknown"
        fi
    fi
}

# 特殊な権限を持つファイルのチェック
# 戻り値:
#   0: 特殊権限を保持する
#   1: 特殊権限を除去する
check_special_permissions() {
    local path="$1"
    local special_files=()
    local has_special=false

    if [ -n "$CTID" ] && pct status "$CTID" | grep -q "status: running"; then
        # コンテナ実行中の場合
        while IFS= read -r file; do
            if [ -n "$file" ]; then
                special_files+=("$file")
                has_special=true
            fi
        done < <(pct exec "$CTID" -- find "$path" -type f \( -perm /4000 -o -perm /2000 -o -perm /1000 \) -print 2>/dev/null || true)
    else
        # コンテナ停止中の場合
        while IFS= read -r file; do
            if [ -n "$file" ]; then
                special_files+=("$file")
                has_special=true
            fi
        done < <(find "$path" -type f \( -perm /4000 -o -perm /2000 -o -perm /1000 \) -print 2>/dev/null || true)
    fi

    if [ "$has_special" = true ]; then
        log_message "WARN" "以下のファイルに特殊な権限が設定されています:"
        printf '%s\n' "${special_files[@]/#/- }"
        if [ "$FORCE" = true ]; then
            log_message "INFO" "特殊な権限を除去して取得します。"
            return 1
        fi
        read -p "これらの権限を保持して取得しますか？ (y/N): " response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            log_message "INFO" "特殊な権限を除去して取得します。"
            return 1
        fi
    fi
    return 0
}

# ACLの処理
handle_acls() {
    local src="$1"
    local dst="$2"
    local has_acl=false

    # ACLツールの存在確認
    if ! command -v getfacl >/dev/null || ! command -v setfacl >/dev/null; then
        log_message "WARN" "ACLツールがインストールされていないため、ACLの処理をスキップします。"
        return 0
    fi

    # ACL用の一時ファイルを作成
    ACL_TEMP_FILE="$(mktemp)"

    # ACLの確認
    if [ -n "$CTID" ] && pct status "$CTID" | grep -q "status: running"; then
        # コンテナ実行中の場合
        if pct exec "$CTID" -- getfacl -R "$src" >/dev/null 2>&1; then
            has_acl=true
        fi
    else
        # コンテナ停止中の場合
        if getfacl -R "$src" >/dev/null 2>&1; then
            has_acl=true
        fi
    fi

    if [ "$has_acl" = true ]; then
        log_message "WARN" "ソースファイルにACLが設定されています。"
        if [ "$FORCE" = true ]; then
            log_message "INFO" "ACLを保持して取得します。"
            response="y"
        else
            read -p "ACLを保持して取得しますか？ (y/N): " response
        fi
        if [[ "$response" =~ ^[Yy]$ ]]; then
            if [ -n "$CTID" ] && pct status "$CTID" | grep -q "status: running"; then
                # コンテナ実行中の場合
                pct exec "$CTID" -- getfacl -R "$src" > "$ACL_TEMP_FILE"
                setfacl --restore="$ACL_TEMP_FILE" -R "$dst"
            else
                # コンテナ停止中の場合
                if [ -d "$src" ]; then
                    getfacl -R "$src" | setfacl --restore=- -R "$dst"
                else
                    getfacl "$src" | setfacl --restore=- "$dst"
                fi
            fi
            log_message "INFO" "ACLを復元しました。"
        fi
    fi

    # ACL用の一時ファイルを削除
    rm -f "$ACL_TEMP_FILE"
}

# 再帰的なファイル衝突とシンボリックリンクのチェック
check_contents_conflict() {
    local source_dir="$1"
    local target_dir="$2"
    
    local symlinks=()
    local conflicts=()

    # ソースディレクトリ内のファイル一覧とシンボリックリンク情報を一度に取得
    if [ -n "$CTID" ] && pct status "$CTID" | grep -q "status: running"; then
        # コンテナ実行中の場合
        while IFS=$'\t' read -r item type; do
            # シンボリックリンクのチェック
            if [ "$type" = "l" ]; then
                symlinks+=("$item")
            fi
            # 既存ファイルの衝突チェック
            if [ -e "$target_dir/$item" ]; then
                conflicts+=("$item")
            fi
        done < <(pct exec "$CTID" -- find "$source_dir" -mindepth 1 -printf '%P\t%y\n')
    else
        # コンテナ停止中の場合
        while IFS=$'\t' read -r item type; do
            if [ "$type" = "l" ]; then
                symlinks+=("$item")
            fi
            if [ -e "$target_dir/$item" ]; then
                conflicts+=("$item")
            fi
        done < <(cd "$source_dir" && find . -mindepth 1 -printf '%P\t%y\n')
    fi

    # シンボリックリンクの警告（セキュリティ上の理由で、-fオプションでもスキップしない）
    if [ ${#symlinks[@]} -gt 0 ]; then
        log_message "WARN" "以下のシンボリックリンクが含まれています:"
        printf '%s\n' "${symlinks[@]/#/- }"
        read -p "シンボリックリンクを取得しますか？ (y/N): " response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            log_message "INFO" "取得を中止します。"
            exit 1
        fi
    fi

    # ファイル衝突の警告
    if [ ${#conflicts[@]} -gt 0 ]; then
        if [ "$FORCE" = true ]; then
            log_message "INFO" "既存のファイルを上書きします。"
        else
            log_message "WARN" "以下のファイル/ディレクトリが既に存在します:"
            printf '%s\n' "${conflicts[@]/#/- }"
            read -p "上書きしますか？ (y/N): " response
            if [[ ! "$response" =~ ^[Yy]$ ]]; then
                log_message "INFO" "取得を中止します。"
                exit 1
            fi
        fi
    fi
}

# パーミッションチェック関数を拡張
check_permissions() {
    local target_dir="$1"
    local parent_dir
    
    # 親ディレクトリが存在しない場合は作成を試みる
    parent_dir="$(dirname "$target_dir")"
    if [ ! -d "$parent_dir" ]; then
        if ! mkdir -p "$parent_dir"; then
            echo "エラー: $parent_dir の作成に失敗しました。"
            exit 1
        fi
    fi

    # ターゲットディレクトリの書き込み権限チェック
    if [ -e "$target_dir" ] && [ ! -w "$target_dir" ]; then
        echo "エラー: $target_dir への書き込み権限がありません。"
        exit 1
    fi

    # 親ディレクトリの書き込み権限チェック
    if [ ! -w "$parent_dir" ]; then
        echo "エラー: $parent_dir への書き込み権限がありません。"
        exit 1
    fi
}

# rsyncでの安全な取得
rsync_with_permissions() {
    local src="$1"
    local dst="$2"
    local preserve_owner=false
    local rsync_opts="-rlptD"  # デフォルトオプション

    # rootユーザーの場合のみ所有者を保持
    if [ "$(id -u)" = "0" ]; then
        preserve_owner=true
        rsync_opts="-a"  # 所有者も含めて全て保持
    fi

    # 特殊権限のチェック
    check_special_permissions "$src"
    local special_perms=$?

    # バッファサイズの設定（大量ファイル対策）
    rsync_opts="$rsync_opts --buffer-size=128K"

    if [ "$special_perms" = 1 ]; then
        # 特殊権限を除去
        rsync_opts="$rsync_opts --chmod=u=rwX,g=rX,o=rX"
    fi

    # 取得の実行
    if ! rsync $rsync_opts "$src" "$dst"; then
        log_message "ERROR" "rsyncでの取得に失敗しました。"
        return 1
    fi

    # ACLの処理
    handle_acls "$src" "$dst"

    return 0
}

# tarでの安全な展開
extract_tar_with_permissions() {
    local tar_file="$1"
    local dst="$2"
    local preserve_owner=false
    local tar_opts="xzf"

    if [ "$(id -u)" = "0" ]; then
        preserve_owner=true
    else
        tar_opts="$tar_opts --no-same-owner"
    fi

    # 特殊権限のチェック
    check_special_permissions "$dst"
    local special_perms=$?

    if [ "$special_perms" = 1 ]; then
        # 特殊権限を除去してデフォルトのumaskを使用
        umask "$DEFAULT_UMASK"
    fi

    # tarの展開
    if ! tar $tar_opts "$tar_file" -C "$dst"; then
        log_message "ERROR" "tarの展開に失敗しました。"
        return 1
    fi

    return 0
}

# コンテナの状態確認とファイルタイプの取得
if pct status "$CTID" | grep -q "status: running"; then
    log_message "INFO" "コンテナは実行中です。pct pullを使用して取得を実行します..."
    
    # パーミッションチェック
    check_permissions "$HOST_PATH"

    # ファイルタイプの確認
    file_type=$(get_file_info "$CONTAINER_PATH")
    case "$file_type" in
        directory)
            IS_DIR="yes"
            ;;
        file)
            IS_DIR="no"
            ;;
        symlink)
            echo "警告: パスがシンボリックリンクです: $CONTAINER_PATH"
            read -p "シンボリックリンクを取得しますか？ (y/N): " response
            if [[ ! "$response" =~ ^[Yy]$ ]]; then
                echo "取得を中止します。"
                exit 1
            fi
            IS_DIR="no"
            ;;
        *)
            echo "エラー: パスの確認に失敗しました: $CONTAINER_PATH"
            exit 1
            ;;
    esac

    if [ "$IS_DIR" = "yes" ]; then
        if [ "$COPY_CONTENTS_ONLY" = true ]; then
            # ディレクトリの中身を取得する場合
            mkdir -p "$HOST_PATH"
            check_contents_conflict "$CONTAINER_PATH" "$HOST_PATH"
        else
            # ディレクトリごと取得する場合、ターゲットの存在チェック
            check_target_exists "$HOST_PATH/$(basename "$CONTAINER_PATH")"
        fi
    else
        # 単一ファイルの場合の存在チェック
        check_target_exists "$HOST_PATH/$(basename "$CONTAINER_PATH")"
    fi
    
    # コンテナ内で一時的なtarファイルを作成
    TEMP_TAR="/tmp/pct_pull_$(date +%Y%m%d_%H%M%S)_$RANDOM.tar"
    HOST_TEMP_DIR=$(mktemp -d)
    HOST_TEMP_TAR="$HOST_TEMP_DIR/temp.tar"

    # tarファイルをコンテナからホストに取得
    if ! pct pull $CTID $TEMP_TAR $HOST_TEMP_TAR; then
        echo "エラー: tarファイルの取得に失敗しました。"
        rm -rf "$HOST_TEMP_DIR"
        pct exec $CTID -- rm -f "$TEMP_TAR"
        exit 1
    fi

    # 出力先ディレクトリが存在しない場合は作成
    mkdir -p "$HOST_PATH"

    # tarファイルを展開（権限を考慮）
    if ! extract_tar_with_permissions "$HOST_TEMP_TAR" "$HOST_PATH"; then
        log_message "ERROR" "ファイルの展開に失敗しました。"
        exit 1
    fi

    # 一時ファイルの削除
    rm -rf "$HOST_TEMP_DIR"
    pct exec $CTID -- rm -f "$TEMP_TAR"

else
    log_message "INFO" "コンテナは停止中です。直接ファイルシステムから取得を実行します..."
    
    # パーミッションチェック
    check_permissions "$HOST_PATH"

    # コンテナのrootfsパスを構築
    ROOTFS_PATH="/var/lib/lxc/$CTID/rootfs"
    
    if [ ! -d "$ROOTFS_PATH" ]; then
        echo "エラー: コンテナのrootfsが見つかりません: $ROOTFS_PATH"
        exit 1
    fi

    # コンテナ内のパスからrootfsパス内の実際のパスを構築
    FULL_SOURCE_PATH="$ROOTFS_PATH$CONTAINER_PATH"
    
    if [ ! -e "$FULL_SOURCE_PATH" ]; then
        echo "エラー: 取得元のパスが存在しません: $CONTAINER_PATH"
        exit 1
    fi

    # ファイルタイプの確認（ディレクトリかファイルか）
    IS_DIR="no"
    if [ -d "$FULL_SOURCE_PATH" ]; then
        IS_DIR="yes"
    fi

    if [ "$IS_DIR" = "yes" ]; then
        if [ "$COPY_CONTENTS_ONLY" = true ]; then
            # ディレクトリの中身を取得する場合
            mkdir -p "$HOST_PATH"
            check_contents_conflict "$FULL_SOURCE_PATH" "$HOST_PATH"
        else
            # ディレクトリごと取得する場合、ターゲットの存在チェック
            check_target_exists "$HOST_PATH/$(basename "$CONTAINER_PATH")"
        fi
    else
        # 単一ファイルの場合の存在チェック
        check_target_exists "$HOST_PATH/$(basename "$CONTAINER_PATH")"
    fi

    # 出力先ディレクトリが存在しない場合は作成
    mkdir -p "$HOST_PATH"

    # rsyncを使用してファイルを取得（権限を考慮）
    if [ "$IS_DIR" = "yes" ]; then
        if [ "$COPY_CONTENTS_ONLY" = true ]; then
            BACKUP_DIR=$(create_backup "$HOST_PATH")
            if ! rsync_with_permissions "$FULL_SOURCE_PATH/" "$HOST_PATH/"; then
                log_message "ERROR" "ファイルの取得に失敗しました。"
                restore_backup "$BACKUP_DIR" "$HOST_PATH"
                exit 1
            fi
        else
            target_dir="$HOST_PATH/$(basename "$CONTAINER_PATH")"
            BACKUP_DIR=$(create_backup "$target_dir")
            if ! rsync_with_permissions "$FULL_SOURCE_PATH" "$HOST_PATH/"; then
                log_message "ERROR" "ファイルの取得に失敗しました。"
                restore_backup "$BACKUP_DIR" "$target_dir"
                exit 1
            fi
        fi
    else
        target_file="$HOST_PATH/$(basename "$CONTAINER_PATH")"
        BACKUP_DIR=$(create_backup "$target_file")
        if ! rsync_with_permissions "$FULL_SOURCE_PATH" "$HOST_PATH/"; then
            log_message "ERROR" "ファイルの取得に失敗しました。"
            restore_backup "$BACKUP_DIR" "$target_file"
            exit 1
        fi
    fi
fi

log_message "INFO" "取得が完了しました。"
if [ "$IS_DIR" = "yes" ]; then
    if [ "$COPY_CONTENTS_ONLY" = true ]; then
        log_message "INFO" "コンテナ $CTID の $CONTAINER_PATH/ の中身を"
        log_message "INFO" "ホストの $HOST_PATH/ 配下に直接取得しました。"
    else
        log_message "INFO" "コンテナ $CTID の $CONTAINER_PATH ディレクトリとその中身を"
        log_message "INFO" "ホストの $HOST_PATH/ 配下に取得しました。"
    fi
else
    log_message "INFO" "コンテナ $CTID の $CONTAINER_PATH ファイルを"
    log_message "INFO" "ホストの $HOST_PATH/ に取得しました。"
fi 