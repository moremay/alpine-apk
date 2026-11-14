#!/bin/bash
#
# 对照某个包在「stable（Alpine 3.x）」「edge」「本地仓库」中的版本，
# 用于判断上游是否已经修掉某个 CVE：
#   - edge 已升到修复版本、stable 还没升  → 要么固定到 edge 的版本，要么自己 backport（见 libxml2/）
#   - stable 已升                          → 直接把 Dockerfile 里的固定版本改成新版本
#   - 三处都一样                            → 本地包没有额外价值，可考虑移除
# 每个通道只显示一行（main/community 取较高者）；版本仅在来自 community 时标注
# "(community)"，便于判断该包能否直接从 defaults 的 main 获得。
#
# 另外会显示「基础镜像」里该包已安装的版本：apk add <pkg> 对已安装的包不会自动升级，
# 所以仓库里虽有新版本、镜像里却是旧版本时，仍然必须显式 pin 才会升级（如 zlib）。
#
# 结论行（三个通道取最高版本，再与基础镜像已装版本比较）：
#   无需pinning                      → 镜像已带最新版，或包里原本没装、apk add 会直接装最新
#   pinning stable <pkg>=<ver>       → 最高版在 stable，但镜像自带更旧的版本，需显式 pin 才会升级
#   pinning edge <pkg>=<ver>         → 需固定到 edge 的版本（或自行 backport，见 libxml2/）
#   pinning local <pkg>=<ver>        → 需固定到本地仓库的包（pkgrel=100，含 backport）

set -e

cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")"

usage() {
  cat >&2 <<EOF
用法: $0 [-m] <pkg...>   例: $0 wolfssl curl libxml2

  -m, --mirrors   用 mirrors.nju.edu.cn 替换 dl-cdn.alpinelinux.org
                  （国内网络访问 dl-cdn 常因 DNS 失败；也可直接 MIRRORS=<镜像站> $0 ...）
  BASE_IMAGE      用哪个镜像查看「已安装版本」，默认 ../Dockerfile.template 里 builder 阶段的镜像
EOF
}

# 镜像站主机名；为空表示用上游 dl-cdn.alpinelinux.org
MIRRORS="${MIRRORS:-}"
DEFAULT_MIRROR=mirrors.nju.edu.cn

pkgs=()
while [ $# -gt 0 ]; do
  case "$1" in
    -m | --mirrors) MIRRORS="${MIRRORS:-$DEFAULT_MIRROR}" ;;
    -h | --help) usage; exit 0 ;;
    --) shift; pkgs+=("$@"); break ;;
    -*) echo "未知选项: $1" >&2; usage; exit 1 ;;
    *) pkgs+=("$1") ;;
  esac
  shift
done

if [ ${#pkgs[@]} -eq 0 ]; then
  usage
  exit 1
fi
set -- "${pkgs[@]}"

# 基础镜像：默认与 ../Dockerfile.template 的 builder 阶段一致（apk add 就装在这个镜像上），
# 找不到模板时退回 alpine。可用 BASE_IMAGE=<镜像:tag> 覆盖。
if [ -z "${BASE_IMAGE:-}" ]; then
  BASE_IMAGE=$(awk 'tolower($1) == "from" && tolower($3) == "as" && $4 == "builder" { print $2; exit }' \
    ../Dockerfile.template 2>/dev/null || true)
  BASE_IMAGE="${BASE_IMAGE:-alpine}"
fi

if ! ls .abuild/*.pub >/dev/null 2>&1; then
  echo "未找到 .abuild/*.pub，请先执行 ./build-apk.sh 生成密钥与产物" >&2
  exit 1
fi

update_log=$(mktemp)
policy_tmp=$(mktemp)
installed_tmp=$(mktemp)
cleanup() { rm -f "$update_log" "$policy_tmp" "$installed_tmp"; docker stop tmp-alpine >/dev/null 2>&1; }
trap cleanup EXIT

if ! docker run -d --rm -v ./:/usr/src/repo --name tmp-alpine "$BASE_IMAGE" sleep infinity >/dev/null; then
  echo "启动容器失败（镜像 $BASE_IMAGE 拉取失败？或容器名 tmp-alpine 被占用？先 docker rm -f tmp-alpine 再试）" >&2
  exit 1
fi

# 基础镜像自带的已安装包 → "name-version"（在改动仓库之前快照，反映镜像原始状态）
docker exec tmp-alpine apk info -v >"$installed_tmp" 2>/dev/null || true

setup_repo() {
  docker exec tmp-alpine sh -c "
cp -f /usr/src/repo/.abuild/*.pub /etc/apk/keys/
echo 'https://dl-cdn.alpinelinux.org/alpine/edge/main' >> /etc/apk/repositories
echo 'https://dl-cdn.alpinelinux.org/alpine/edge/community' >> /etc/apk/repositories
echo '/usr/src/repo/' >> /etc/apk/repositories
if [ -n '$1' ]; then sed 's/dl-cdn.alpinelinux.org/$1/g' -i /etc/apk/repositories; fi
"
}

switch_mirror() { # switch_mirror <host>
  docker exec tmp-alpine sed "s/dl-cdn.alpinelinux.org/$1/g" -i /etc/apk/repositories
}

setup_repo "$MIRRORS"

apk_update() { docker exec tmp-alpine apk update >"$update_log" 2>&1; }

update_failed=0
if ! apk_update; then
  if [ -z "$MIRRORS" ]; then
    echo "dl-cdn.alpinelinux.org 不可用（网络/DNS？），改用 ${DEFAULT_MIRROR} 重试……" >&2
    MIRRORS="$DEFAULT_MIRROR"
    switch_mirror "$MIRRORS" || true
    apk_update || update_failed=1
  else
    update_failed=1
  fi
fi

if [ "$update_failed" = 1 ]; then
  echo "apk update 失败（仓库源不可用）：" >&2
  sed 's/^/  /' "$update_log" >&2
  echo "提示: 用 -m 或 MIRRORS=<镜像站> 指定可用的 Alpine 镜像源" >&2
  exit 1
fi

release=$(docker exec tmp-alpine cat /etc/alpine-release)
stable="v${release%.*}"

docker exec tmp-alpine apk policy "$@" >"$policy_tmp" 2>&1 || true

# apk policy 输出 → pkg<TAB>repo<TAB>ver
parsed=$(awk '
  /^[^ ].* policy:$/ { pkg = $1; next }
  /^  [^ ]+:$/       { ver = $1; sub(/:$/, "", ver); next }
  /^    [^ ]+$/      { print pkg "\t" $1 "\t" ver }
' "$policy_tmp")

ver_of() { # ver_of <pkg> <repo 前缀>
  printf '%s\n' "$parsed" | awk -F'\t' -v p="$1" -v r="$2" \
    '$1 == p && (index($2, r) == 1 || substr($2, length($2) - length(r) + 1) == r) { print $3 }' \
    | sort -V | tail -1
}

# channel_ver <pkg> <stable|edge|本地仓库> → 打印 "版本" 或 "版本 (community)"
channel_ver() {
  local pkg="$1" chan="$2" main_v comm_v
  case "$chan" in
    stable) main_v=$(ver_of "$pkg" "/${stable}/main"); comm_v=$(ver_of "$pkg" "/${stable}/community") ;;
    edge)   main_v=$(ver_of "$pkg" "/edge/main");       comm_v=$(ver_of "$pkg" "/edge/community") ;;
    本地仓库) main_v=$(ver_of "$pkg" "/usr/src/repo");  comm_v="" ;;
    *) return 0 ;;
  esac
  if [ -z "$main_v" ]; then
    [ -n "$comm_v" ] && echo "$comm_v (community)"
    return 0
  fi
  if [ -n "$comm_v" ] && [ "$(printf '%s\n%s\n' "$main_v" "$comm_v" | sort -V | tail -1)" = "$comm_v" ]; then
    echo "$comm_v (community)"
  else
    echo "$main_v"
  fi
}

plain_ver() { # 去掉 " (community)" 后缀
  printf '%s' "${1% (community)}"
}

base_v_of() { # base_v_of <pkg> → 基础镜像里已装版本；未安装则空
  awk -v p="$1" 'index($0, p "-") == 1 {
      v = substr($0, length(p) + 2)
      if (v ~ /^[0-9]/) { print v; exit }
    }' "$installed_tmp"
}

echo "Alpine ${release}（stable: ${stable} + edge）"
echo "基础镜像 = ${BASE_IMAGE}（apk add 就执行在这个镜像上）"
echo "本地仓库 = /usr/src/repo（本仓库 ./build-apk.sh 产物）"
echo "=========================="

for pkg in "$@"; do
  echo "$pkg"
  stable_v=$(channel_ver "$pkg" stable)
  edge_v=$(channel_ver "$pkg" edge)
  local_v=$(channel_ver "$pkg" 本地仓库)
  base_v=$(base_v_of "$pkg")

  printf '  %-24s %s\n' "${stable_v:--}" "stable (${stable})"
  printf '  %-24s %s\n' "${edge_v:--}" "edge"
  printf '  %-24s %s\n' "${local_v:--}" "本地仓库"
  printf '  %-24s %s\n' "${base_v:--}" "基础镜像 (${BASE_IMAGE})"

  stable_plain=$(plain_ver "$stable_v")
  edge_plain=$(plain_ver "$edge_v")
  local_plain=$(plain_ver "$local_v")

  # 取三处最高版本，结论给出是否需要在 Dockerfile 里 pin。
  # 比较的是完整版本号（含 -rN），pkgrel 参与比较且不忽略：
  #   2.13.9-r100（本地）> 2.13.9-r3（edge）> 2.13.9-r2（stable）
  # 仅当版本号完全相同时才按 stable > edge > local 取（官方补丁优先于本地 backport）。
  newest_ch=""
  newest_v=""
  for pair in "stable:$stable_plain" "edge:$edge_plain" "local:$local_plain"; do
    ch=${pair%%:*}
    v=${pair#*:}
    [ -z "$v" ] && continue
    if [ -z "$newest_v" ] || [ "$(docker exec tmp-alpine apk version -t "$v" "$newest_v")" = '>' ]; then
      newest_ch=$ch
      newest_v=$v
    fi
  done

  # 最高版不在 stable：照旧固定到 edge / 本地仓库。
  # 最高版就是 stable 时还要看基础镜像：apk add 不会自动升级已安装的包，
  # 镜像自带 1.3.2-r1、stable 已是 1.4-r0 这种情况必须显式 pin 才能升上去。
  if [ -z "$newest_v" ]; then
    echo "  => 三处均未找到该包"
  elif [ "$newest_ch" != stable ]; then
    echo "  => pinning ${newest_ch} ${pkg}=${newest_v}"
  elif [ -z "$base_v" ]; then
    # 镜像里没装该包，apk add 会直接装 stable 的最新版，无需 pin
    echo "  => 无需pinning"
  elif [ "$(docker exec tmp-alpine apk version -t "$base_v" "$newest_v")" = '<' ]; then
    echo "  => pinning stable ${pkg}=${newest_v}（基础镜像只有 ${base_v}，不 pin 不会升级）"
  else
    echo "  => 无需pinning（基础镜像已带 ${base_v}）"
  fi
  echo "=========================="
done
