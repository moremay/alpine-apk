#!/bin/bash
#
# 对照某个包在「稳定仓库（Alpine 3.x main/community）」「edge」「本地仓库」中的版本，
# 用于判断上游是否已经修掉某个 CVE：
#   - edge 已升到修复版本、稳定仓库还没升  → 要么固定到 edge 的版本，要么自己 backport（见 libxml2/）
#   - 稳定仓库已升                          → 直接把 Dockerfile 里的固定版本改成新版本
#   - 三处都一样                            → 本地包没有额外价值，可考虑移除
#

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

repo_label() {
  case "$1" in
    /usr/src/repo*)                 echo "本地仓库" ;;
    *"/edge/main"*)                 echo "edge/main" ;;
    *"/edge/community"*)            echo "edge/community" ;;
    *"/${stable}/main"*)            echo "${stable}/main" ;;
    *"/${stable}/community"*)       echo "${stable}/community" ;;
    *)                              echo "$1" ;;
  esac
}

ver_of() { # ver_of <pkg> <repo-label>
  printf '%s\n' "$parsed" | awk -F'\t' -v p="$1" -v r="$2" '$1 == p && $3 != "" {
    label = $2
    if (label ~ /^\/usr\/src\/repo/) label = "本地仓库"
    else if (label ~ /\/edge\/main/) label = "edge/main"
    else if (label ~ /\/edge\/community/) label = "edge/community"
    else if (label ~ /\/v[^\/]*\/main/) { n = split(label, a, "/"); label = a[n-1] "/main" }
    else if (label ~ /\/v[^\/]*\/community/) { n = split(label, a, "/"); label = a[n-1] "/community" }
    if (label == r) print $3
  }' | sort -V | tail -1
}

max_ver() { sort -V | tail -1; }

echo "Alpine ${release}（stable: ${stable} + edge）"
echo "本地仓库 = /usr/src/repo（本仓库 ./build-apk.sh 产物）"
echo "=========================="

for pkg in "$@"; do
  echo "$pkg"
  local_ver=""
  for label in "${stable}/main" "${stable}/community" edge/main edge/community 本地仓库; do
    ver=$(ver_of "$pkg" "$label")
    [ "$label" = "本地仓库" ] && local_ver="$ver"
    printf '  %-16s %s\n' "${ver:--}" "$label"
  done

  upstream=$(printf '%s\n' "$parsed" | awk -F'\t' -v p="$pkg" '$1 == p && $2 !~ /^\/usr\/src\/repo/ { print $3 }' | max_ver)
  if [ -n "$local_ver" ] && [ -n "$upstream" ]; then
    cmp=$(docker exec tmp-alpine apk version -t "$local_ver" "$upstream")
    case "$cmp" in
      '>') echo "  => 本地 $local_ver 高于上游最新 $upstream" ;;
      '=') echo "  => 本地 $local_ver 与上游最新一致" ;;
      *)   echo "  => 本地 $local_ver 低于上游最新 $upstream" ;;
    esac
  elif [ -z "$local_ver" ] && [ -z "$upstream" ]; then
    echo "  => 四个仓库中均未找到该包"
  elif [ -z "$local_ver" ]; then
    echo "  => 本地无该包（上游最新 $upstream）"
  elif [ -z "$upstream" ]; then
    echo "  => 仅本地有该包（$local_ver）"
  fi
  echo "=========================="
done
