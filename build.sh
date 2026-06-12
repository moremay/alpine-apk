#!/bin/sh
set -e

usage() {
    echo "Usage: ./build.sh <pkgname>..."
}

if [ 0 -eq $# ]; then
    usage
    exit 1
fi

if ! command -v abuild >/dev/null; then
    apk add alpine-sdk
fi

if [ ! -f ~/.abuild/abuild.conf ]; then
    mkdir -p ~/.abuild
    cat >~/.abuild/abuild.conf <<EOF
PACKAGER="Your Name <you@example.com>"
MAINTAINER="\$PACKAGER"
REPODEST=/
EOF

    abuild-keygen -an
fi

grep -q '/root' /etc/apk/repositories || echo '/root/' >>/etc/apk/repositories

for pkgname in "$@"; do
    cd ~/$pkgname
    abuild -F fetch
    abuild -F -r || true
    ~/update.sh
    apk add -X /root/ --allow-untrusted $pkgname-dev
done
