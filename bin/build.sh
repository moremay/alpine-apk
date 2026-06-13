#!/bin/sh
set -e

if [ 0 -eq $# ]; then
    echo "Usage: ./build.sh <pkgname>..."
    exit 1
fi

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

for pkgname in "$@"; do
    cd ~/$pkgname
    abuild -F fetch
    abuild -F -r

    cd ~/x86_64
    apk index --allow-untrusted -o APKINDEX.tar.gz *.apk
    abuild-sign APKINDEX.tar.gz
done
