#!/bin/bash
set -e

if [ $# -eq 0 ]; then
    set -- wolfssl curl
fi

cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
docker run -it --rm -v ./:/root alpine /root/bin/build.sh "$@"
