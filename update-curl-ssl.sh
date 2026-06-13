#!/bin/bash
#
# update-curl-ssl.sh — 从 Alpine GitLab 拉取 curl/wolfssl 上游 APKBUILD 及补丁文件，
#                       并应用定制修改（pkgrel=100, --with-wolfssl, --enable-curl 等）。
#
# curl 和 wolfssl 紧密相关，必须同时处理：
#   1. 在 curl.tmp / wolfssl.tmp 临时目录中完成所有操作
#   2. 全部成功后，原目录 → .bak，.tmp → 正式目录名
#   3. 任何步骤失败则清理 .tmp 目录，原目录不受影响

set -eo pipefail

# ──────────────────────────────────────────────
# 全局常量
# ──────────────────────────────────────────────
SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"

# Alpine aports GitLab 仓库（使用 numeric ID 更可靠）
ALPINE_GITLAB_API="https://gitlab.alpinelinux.org/api/v4/projects/1/repository"
ALPINE_GITLAB_RAW="https://gitlab.alpinelinux.org/alpine/aports/-/raw/master"

# curl 在 main/，wolfssl 在 community/（Alpine edge/master 分支）
PKG_CURL="curl"
PKG_CURL_PATH="main/curl"
PKG_WOLFSSL="wolfssl"
PKG_WOLFSSL_PATH="community/wolfssl"

# ──────────────────────────────────────────────
# 辅助函数
# ──────────────────────────────────────────────

# 检查并安装必要的依赖
check_deps() {
    if ! command -v jq &>/dev/null; then
        echo "[安装] jq..."
        apt update -qq && apt install -y -qq jq
    fi
}

# 从 GitLab 列出指定目录下的所有文件（仅文件名）
list_upstream_files() {
    local repo_path="$1"
    local api_url="$ALPINE_GITLAB_API/tree?path=$repo_path&ref=master&per_page=100"
    local tmpfile
    tmpfile=$(mktemp)

    if ! curl -sL "$api_url" -o "$tmpfile"; then
        rm -f "$tmpfile"
        echo "[错误] 无法从 GitLab API 获取 $repo_path 的文件列表" >&2
        return 1
    fi

    # 使用 jq 解析 JSON 提取文件名
    local files
    files=$(jq -r '.[] | select(.type=="blob") | .name' "$tmpfile" || :)
    rm -f "$tmpfile"

    if [ -z "$files" ]; then
        echo "[错误] $repo_path 上游文件列表为空，可能 API 返回异常" >&2
        return 1
    fi

    echo "$files"
}

# 从 GitLab 下载指定目录的所有文件到目标目录
fetch_upstream_files() {
    local pkg="$1"
    local repo_path="$2"
    local dest_dir="$3"

    mkdir -p "$dest_dir"

    echo "从 GitLab 获取 $pkg 上游文件列表 ($repo_path/)..."
    local files
    files=$(list_upstream_files "$repo_path")

    # 使用 <<< 避免管道创建子 shell，确保错误能正常返回
    local count=0
    while read -r filename; do
        [ -z "$filename" ] && continue
        local raw_url="$ALPINE_GITLAB_RAW/$repo_path/$filename"
        local dest_file="$dest_dir/$filename"
        echo "    $repo_path/$filename"
        if ! curl -sL "$raw_url" -o "$dest_file"; then
            echo "[错误] 下载失败: $raw_url" >&2
            return 1
        fi
        count=$((count + 1))
    done <<<"$files"

    echo "    已下载 $count 个文件到 $dest_dir"
}

# 从 APKBUILD 中提取 pkgver
get_pkgver() {
    local apkbuild_file="$1"
    if [ ! -f "$apkbuild_file" ]; then
        echo "[错误] 找不到 wolfssl APKBUILD: $apkbuild_file" >&2
        return 1
    fi
    grep -oP '^pkgver=\K[0-9.]+' "$apkbuild_file" || true
}

# ──────────────────────────────────────────────
# 修改函数
# ──────────────────────────────────────────────

# 修改 curl APKBUILD
modify_curl_apkbuild() {
    local file="$SCRIPT_DIR/$PKG_CURL.tmp/APKBUILD"

    local wolfssl_pkgver=$(get_pkgver "$SCRIPT_DIR/$PKG_WOLFSSL.tmp/APKBUILD")
    if [ -z "$wolfssl_pkgver" ]; then
        echo "[错误] 无法从 wolfssl APKBUILD 提取 pkgver" >&2
        return 1
    fi

    echo "    v$(grep -oP '^pkgver=\K[0-9.]+' "$file" || true)"

    sed -i 's/^pkgrel=[0-9]\+$/pkgrel=100/' "$file"

    # openssl-dev → wolfssl-dev=<ver>-r100
    sed -i "s/^[[:space:]]*openssl-dev[^ ]*/\\twolfssl-dev=${wolfssl_pkgver}-r100/" "$file"

    # --with-openssl → --with-wolfssl
    sed -i 's/--with-openssl/--with-wolfssl/' "$file"
}

# 修改 wolfssl APKBUILD
modify_wolfssl_apkbuild() {
    local file="$SCRIPT_DIR/$PKG_WOLFSSL.tmp/APKBUILD"

    echo "    v$(grep -oP '^pkgver=\K[0-9.]+' "$file" || true)"

    sed -i 's/^pkgrel=[0-9]\+$/pkgrel=100/' "$file"

    if ! grep -q '\--enable-curl' "$file"; then
        sed -i '/^[[:space:]]*--enable-shared \\/i\\t\t--enable-curl \\' "$file"
    fi

    # --enable-examples → --disable-examples（wolfssl 作为库不需要编译示例）
    sed -i 's/--enable-examples/--disable-examples/' "$file"
}

# ──────────────────────────────────────────────
# 核心处理函数（处理单个包）
# ──────────────────────────────────────────────

process_pkg() {
    local pkg="$1"
    local repo_path="$2"
    local src_dir="$SCRIPT_DIR/$pkg"
    local tmp_dir="${src_dir}.tmp"

    echo ""
    echo "=== $pkg"

    # 清理可能残留的 .tmp 目录
    if [ -d "$tmp_dir" ]; then
        echo "清理临时目录: $tmp_dir"
        rm -rf "$tmp_dir"
    fi

    fetch_upstream_files "$pkg" "$repo_path" "$tmp_dir"

    echo "应用修改 ..."
    case "$pkg" in
    "$PKG_CURL")
        modify_curl_apkbuild
        ;;
    "$PKG_WOLFSSL")
        modify_wolfssl_apkbuild
        ;;
    esac

    echo "    处理完毕 $tmp_dir"
}

# 更新：.tmp → 正式名，原目录 → .bak
# 异常恢复：如果原目录不存在但 .bak 存在（上次中断），跳过备份直接替换
atomic_swap() {
    local pkg="$1"
    local src_dir="$SCRIPT_DIR/$pkg"
    local tmp_dir="${src_dir}.tmp"
    local bak_dir="${src_dir}.bak"

    if [ ! -d "$tmp_dir" ]; then
        echo "[错误] 临时目录不存在，无法完成更新: $tmp_dir" >&2
        return 1
    fi

    if [ -d "$src_dir" ]; then
        # 正常流程：原目录 → .bak，.tmp → 正式名
        if [ -d "$bak_dir" ]; then
            echo "    删除旧的备份目录: $bak_dir"
            rm -rf "$bak_dir"
        fi
        mv "$src_dir" "$bak_dir"
    elif [ -d "$bak_dir" ]; then
        # 异常恢复：原目录不存在但 .bak 存在，说明上次 mv src→bak 成功
        # 但 mv tmp→src 被中断，跳过备份步骤
        echo "    $pkg: 原目录不存在，检测到备份目录，跳过备份"
    fi

    mv "$tmp_dir" "$src_dir"

    if [ -d "$bak_dir" ]; then
        echo "    $pkg 已更新 (备份: $bak_dir)"
    else
        echo "    $pkg 已更新 (首次运行，无备份)"
    fi
}

# 失败时清理 .tmp 目录
cleanup_on_failure() {
    local pkg="$1"
    local tmp_dir="$SCRIPT_DIR/${pkg}.tmp"
    if [ -d "$tmp_dir" ]; then
        echo "[清理] 删除临时目录: $tmp_dir"
        rm -rf "$tmp_dir"
    fi
}

# ──────────────────────────────────────────────
# 主逻辑
# ──────────────────────────────────────────────

main() {
    check_deps

    # 先处理 wolfssl（curl 需要其 pkgver）
    process_pkg "$PKG_WOLFSSL" "$PKG_WOLFSSL_PATH" || {
        cleanup_on_failure "$PKG_WOLFSSL"
        exit 1
    }
    process_pkg "$PKG_CURL" "$PKG_CURL_PATH" || {
        cleanup_on_failure "$PKG_WOLFSSL"
        cleanup_on_failure "$PKG_CURL"
        exit 1
    }

    echo ""
    echo "=== 更新"

    # 全部成功后更新
    atomic_swap "$PKG_WOLFSSL" || exit 1
    atomic_swap "$PKG_CURL" || exit 1

    echo ""
    echo "=== 成功完成！"
}

main
