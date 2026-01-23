#!/bin/sh
set -e

cd ~/x86_64
apk index --allow-untrusted -o APKINDEX.tar.gz *.apk
