#!/bin/bash
#
# 对照某个包在「stable（Alpine 3.x）」「edge」「本地仓库」中的版本，
# 用于判断上游是否已经修掉某个 CVE：
#   - edge 已升到修复版本、stable 还没升  → 要么固定到 edge 的版本，要么自己 backport（见 libxml2/）
#   - stable 已升                          → 直接把 Dockerfile 里的固定版本改成新版本
#   - 三处都一样                            → 本地包没有额外价值，可考虑移除
#
# 每个通道只显示一行（main/community 取较高者）；版本仅在来自 community 时标注
# "(community)"，便于判断该包能否直接从 defaults 的 main 获得。

set -e

cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")"

if [ $# -eq 0 ]; then
  echo "用法: $0 <pkg...>   例: $0 wolfssl curl libxml2" >&2
  exit 1
fi

if ! ls .abuild/*.pub >/dev/null 2>&1; then
  echo "未找到 .abuild/*.pub，请先执行 ./build-apk.sh 生成密钥与产物" >&2
  exit 1
fi

docker run -d --rm -v ./:/usr/src/repo --name tmp-alpine alpine sleep infinity >/dev/null
trap "docker stop tmp-alpine >/dev/null 2>&1" EXIT

docker exec tmp-alpine sh -c "
cp -f /usr/src/repo/.abuild/*.pub /etc/apk/keys/
echo 'https://dl-cdn.alpinelinux.org/alpine/edge/main' >> /etc/apk/repositories
echo 'https://dl-cdn.alpinelinux.org/alpine/edge/community' >> /etc/apk/repositories
echo '/usr/src/repo/' >> /etc/apk/repositories
apk update
" >/dev/null 2>&1

release=$(docker exec tmp-alpine cat /etc/alpine-release)
stable="v${release%.*}"
policy_tmp=$(mktemp)
trap "rm -f '$policy_tmp'; docker stop tmp-alpine >/dev/null 2>&1" EXIT

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

max_ver() { sort -V | tail -1; }

echo "Alpine ${release}（stable: ${stable} + edge）"
echo "本地仓库 = /usr/src/repo（本仓库 ./build-apk.sh 产物）"
echo "=========================="

for pkg in "$@"; do
  echo "$pkg"
  stable_v=$(channel_ver "$pkg" stable)
  edge_v=$(channel_ver "$pkg" edge)
  local_v=$(channel_ver "$pkg" 本地仓库)

  printf '  %-24s %s\n' "${stable_v:--}" "stable (${stable})"
  printf '  %-24s %s\n' "${edge_v:--}" "edge"
  printf '  %-24s %s\n' "${local_v:--}" "本地仓库"

  upstream=$(printf '%s\n%s\n' "$(plain_ver "$stable_v")" "$(plain_ver "$edge_v")" | grep -v '^$' | max_ver)
  local_plain=$(plain_ver "$local_v")

  if [ -n "$local_plain" ] && [ -n "$upstream" ]; then
    cmp=$(docker exec tmp-alpine apk version -t "$local_plain" "$upstream")
    case "$cmp" in
      '>') echo "  => 本地 $local_plain 高于上游最新 $upstream" ;;
      '=') echo "  => 本地 $local_plain 与上游最新一致" ;;
      *)   echo "  => 本地 $local_plain 低于上游最新 $upstream" ;;
    esac
  elif [ -z "$local_plain" ] && [ -z "$upstream" ]; then
    echo "  => 三处均未找到该包"
  elif [ -z "$local_plain" ]; then
    echo "  => 本地无该包（上游最新 $upstream）"
  else
    echo "  => 仅本地有该包（$local_plain）"
  fi
  echo "=========================="
done
