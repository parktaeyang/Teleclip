#!/bin/zsh
# Teleclip 빌드 스크립트
set -e
cd "$(dirname "$0")"
swiftc -O teleclip.swift -o teleclip
echo "빌드 완료: $(pwd)/teleclip"
