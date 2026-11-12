#!/bin/bash
#
# update-libxml2.sh — 从 Alpine GitLab 拉取 libxml2 上游 APKBUILD 及补丁文件，
#                     追加 CVE backport 补丁，并应用定制修改（pkgrel=100）。
#
# Alpine 的 libxml2 长期停留在 2.13.9-r2，2.15.4 修复的一批 CVE 一直没有
# backport（见 https://gitlab.alpinelinux.org/alpine/aports/-/issues/18550）。
# 本脚本在拉取上游包的基础上，把 libxml2-backports/ 下的 backport 补丁一并
# 打进 2.13.9，产出 libxml2-2.13.9-r100.apk。
#
# 流程：
#   1. 在 libxml2.tmp 临时目录中完成所有操作
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

# libxml2 在 main/
PKG_LIBXML2="libxml2"
PKG_LIBXML2_PATH="main/libxml2"

# 本地 backport 补丁目录（手工维护，随上游 2.15.x 安全修复更新）
BACKPORT_DIR="$SCRIPT_DIR/libxml2-backports"
# 顺序即 source= 中的顺序：86141 依赖 86137 的改动，必须排在后面
BACKPORT_PATCHES="
CVE-2026-86137.patch
CVE-2026-86138.patch
CVE-2026-86139.patch
CVE-2026-86140.patch
CVE-2026-86141.patch
CVE-2026-86142.patch
CVE-2026-86143.patch
CVE-2026-86144.patch
"

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
    if ! files=$(list_upstream_files "$repo_path"); then
        echo "[错误] 获取 $pkg 上游文件列表失败" >&2
        return 1
    fi

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
        if [ ! -s "$dest_file" ]; then
            echo "[错误] 下载内容为空: $raw_url" >&2
            return 1
        fi
        count=$((count + 1))
    done <<<"$files"

    echo "    已下载 $count 个文件到 $dest_dir"

    if [ ! -s "$dest_dir/APKBUILD" ]; then
        echo "[错误] 上游 APKBUILD 缺失" >&2
        return 1
    fi
}

# 把本地 backport 补丁复制到目标目录
copy_backport_patches() {
    local dest_dir="$1"
    local patch

    for patch in $BACKPORT_PATCHES; do
        if [ ! -f "$BACKPORT_DIR/$patch" ]; then
            echo "[错误] 缺少 backport 补丁: $BACKPORT_DIR/$patch" >&2
            return 1
        fi
        echo "    补丁 $patch"
        cp "$BACKPORT_DIR/$patch" "$dest_dir/$patch"
    done
}

# 在 source="..." 结束引号前追加补丁文件名
add_source_entries() {
    local file="$1"
    local patches="$2"

    awk -v patches="$patches" '
        BEGIN { n = split(patches, p, " ") }
        /^source="/ { in_src = 1 }
        in_src && !added && /^[[:space:]]*"$/ {
            for (i = 1; i <= n; i++) print "\t" p[i]
            added = 1
        }
        { print }
    ' "$file" >"$file.new"
    mv "$file.new" "$file"

    if [ -z "$(sed -n '/^source="/,/^[[:space:]]*"$/p' "$file" | grep -F "$(echo "$patches" | cut -d' ' -f1)")" ]; then
        echo "[错误] 未能把补丁加入 source=: $file" >&2
        return 1
    fi
}

# 在 sha512sums="..." 结束引号前追加补丁校验和
add_sha512_entries() {
    local file="$1"
    local dir="$2"
    local patches="$3"
    local sums=""
    local patch

    for patch in $patches; do
        sums="${sums}$(sha512sum -- "$dir/$patch" | cut -d' ' -f1)  $patch"$'\n'
    done

    awk -v sums="$sums" '
        BEGIN { n = split(sums, s, "\n") }
        /^sha512sums="/ { in_sums = 1 }
        in_sums && !added && /^"$/ {
            for (i = 1; i <= n; i++) if (s[i] != "") print s[i]
            added = 1
        }
        { print }
    ' "$file" >"$file.new"
    mv "$file.new" "$file"

    for patch in $patches; do
        if ! grep -q "  $patch\$" "$file"; then
            echo "[错误] 未能把 $patch 的校验和加入 sha512sums" >&2
            return 1
        fi
    done
}

# 在 # secfixes: 后插入本次补丁对应的 CVE 列表
add_secfixes() {
    local file="$1"
    local patches="$2"
    local entry="#   2.13.9-r100:"$'\n'
    local patch

    for patch in $patches; do
        entry="${entry}#     - ${patch%.patch}"$'\n'
    done

    awk -v entry="$entry" '
        { print }
        !added && /^# secfixes:/ {
            printf "%s", entry
            added = 1
        }
    ' "$file" >"$file.new"
    mv "$file.new" "$file"
}

# 生成后自检：APKBUILD 与补丁必须齐全，否则视为失败
verify_package_dir() {
    local dir="$1"
    local file="$dir/APKBUILD"
    local patch

    if [ ! -s "$file" ]; then
        echo "[错误] APKBUILD 为空: $file" >&2
        return 1
    fi

    if ! grep -q '^pkgrel=100$' "$file"; then
        echo "[错误] pkgrel 未改成 100" >&2
        return 1
    fi

    for patch in $BACKPORT_PATCHES; do
        if [ ! -s "$dir/$patch" ]; then
            echo "[错误] 缺少补丁文件: $dir/$patch" >&2
            return 1
        fi
        if ! sed -n '/^source="/,/^[[:space:]]*"$/p' "$file" | grep -qx "[[:space:]]*$patch"; then
            echo "[错误] source= 中缺少 $patch" >&2
            return 1
        fi
        if ! grep -q "  $patch\$" "$file"; then
            echo "[错误] sha512sums 中缺少 $patch" >&2
            return 1
        fi
    done

    if ! grep -q '^#   2.13.9-r100:$' "$file"; then
        echo "[错误] secfixes 中缺少 2.13.9-r100" >&2
        return 1
    fi
}

# ──────────────────────────────────────────────
# 修改函数
# ──────────────────────────────────────────────

# 修改 libxml2 APKBUILD
modify_libxml2_apkbuild() {
    local file="$SCRIPT_DIR/$PKG_LIBXML2.tmp/APKBUILD"
    local dir="$SCRIPT_DIR/$PKG_LIBXML2.tmp"
    local patches
    patches=$(echo $BACKPORT_PATCHES)

    echo "    v$(grep -oP '^pkgver=\K[0-9.]+' "$file" || true)"

    sed -i 's/^pkgrel=[0-9]\+$/pkgrel=100/' "$file"

    add_source_entries "$file" "$patches" || return 1
    add_sha512_entries "$file" "$dir" "$patches" || return 1
    add_secfixes "$file" "$patches" || return 1
    verify_package_dir "$dir" || return 1
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

    if ! fetch_upstream_files "$pkg" "$repo_path" "$tmp_dir"; then
        echo "[错误] 拉取 $pkg 上游文件失败" >&2
        return 1
    fi

    echo "复制 backport 补丁 ..."
    if ! copy_backport_patches "$tmp_dir"; then
        return 1
    fi

    echo "应用修改 ..."
    case "$pkg" in
    "$PKG_LIBXML2")
        if ! modify_libxml2_apkbuild; then
            return 1
        fi
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

    process_pkg "$PKG_LIBXML2" "$PKG_LIBXML2_PATH" || {
        cleanup_on_failure "$PKG_LIBXML2"
        exit 1
    }

    echo ""
    echo "=== 更新"

    atomic_swap "$PKG_LIBXML2" || exit 1

    echo ""
    echo "=== 成功完成！"
}

main
