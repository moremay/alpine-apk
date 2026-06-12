#!/bin/bash
set -e

cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
docker run -it --rm -v ./:/root alpine /root/build.sh wolfssl curl
