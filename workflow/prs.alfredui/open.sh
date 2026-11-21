#!/bin/bash
set -euo pipefail
url="${1:-}"
if [[ "$url" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/(pull|issues)/[0-9]+$ ]]; then
    /usr/bin/jq -n --arg url "$url" '{finish: {args: $url}}'
fi
