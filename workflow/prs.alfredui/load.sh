#!/bin/bash
set -euo pipefail

cd -- "$(dirname -- "$0")"
case "$(/usr/bin/uname -m)" in
    arm64) exec ./dashboard-arm64 "$@" ;;
    x86_64) exec ./dashboard-amd64 "$@" ;;
    *) printf 'Unsupported macOS architecture\n' >&2; exit 1 ;;
esac
