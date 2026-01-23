#!/bin/sh
set -e

usage() {
    echo "Usage: ./build.sh <pkgname>"
}

pkgname="$1"
if [ -z "$pkgname" ]; then
    usage
    exit 1
fi

if [ ! -d ~/$pkgname ]; then
    echo "~/$pkgname : No such directory"
    exit 1
fi

if ! command -v abuild >/dev/null; then
    apk add alpine-sdk
fi

if [ ! -f ~/.abuild/abuild.conf ]; then
    mkdir -p ~/.abuild
    cat > ~/.abuild/abuild.conf << EOF
PACKAGER="Your Name <you@example.com>"
MAINTAINER="\$PACKAGER"
REPODEST=/
EOF

    abuild-keygen -an
fi

cd ~/$pkgname

abuild -F fetch
abuild -F -r || true

~/update.sh
