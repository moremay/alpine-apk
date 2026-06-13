#!/bin/sh
set -e

# 无参数 → 扫描 /root/ 下所有含 APKBUILD 的目录（排除 *.bak）
if [ $# -eq 0 ]; then
    set -- $(find /root -maxdepth 3 -name APKBUILD ! -path '*/.bak/*' ! -path '*.bak/*' \
        -exec dirname {} \; | sed 's|/root/||' | sort -u)
fi

if [ $# -eq 0 ]; then
    echo "No APKBUILD found, nothing to build."
    exit 0
fi

# wolfssl 优先构建
case " $* " in *\ wolfssl\ *)
  set -- wolfssl $(printf '%s\n' "$@" | grep -vx wolfssl)
esac

if ! command -v abuild >/dev/null; then
    apk add alpine-sdk
fi

get_keys() {
    key_file="$(grep 'PACKAGER_PRIVKEY=' ~/.abuild/abuild.conf | sed -e 's/PACKAGER_PRIVKEY=//' -e 's/"//g' || :)"
    pub_file="${key_file}.pub"
}

new_keys() {
    rm -rf ~/.abuild
    rm -f ~/x86_64/APKINDEX.tar.gz
    mkdir -p ~/.abuild
    cat >~/.abuild/abuild.conf <<'EOF'
PACKAGER="Your Name <you@example.com>"
MAINTAINER="$PACKAGER"
REPODEST=/
EOF

    abuild-keygen -an
}

get_keys
if [ ! -f ~/.abuild/abuild.conf ] || [ -z "${key_file}" ] || [ ! -f "${key_file}" ] || [ ! -f "${pub_file}" ]; then
    new_keys
    get_keys
fi
cp -f ~/.abuild/*.pub /etc/apk/keys/

grep -q '/root' /etc/apk/repositories || echo '/root/' >>/etc/apk/repositories

# 构建前：用当前密钥重签已存在的包索引
cd ~/x86_64
if ls *.apk >/dev/null 2>&1; then
    apk index --allow-untrusted -o APKINDEX.tar.gz *.apk
    abuild-sign APKINDEX.tar.gz
fi

# 逐包构建 + 签名
for pkgname in "$@"; do
    cd ~/$pkgname
    abuild -F fetch
    abuild -F -r

    cd ~/x86_64
    apk index --allow-untrusted -o APKINDEX.tar.gz *.apk
    abuild-sign APKINDEX.tar.gz
done
