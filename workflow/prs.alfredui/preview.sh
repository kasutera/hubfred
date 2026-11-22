#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"

url="${1:-}"
if [[ ! "$url" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/(pull|issues)/[0-9]+$ ]]; then
    printf '%s\n' '{"update":{"ids":{"preview":{"text":"<!doctype html><html><body></body></html>"}}}}'
    exit 0
fi
source ./cache.sh

read_body() {
    if [[ "$dashboard_auth_resolved" != true || ! -r "$cache" ]]; then
        printf 'Preview unavailable.'
        return
    fi

    cache_sqlite -readonly "$cache" "
        SELECT body FROM bodies WHERE url = '$url'
        AND EXISTS (SELECT 1 FROM dashboard WHERE identity = '$identity');
    " | /usr/bin/jq -rs '
        if length == 0 then "Preview unavailable."
        elif .[0] == "" then "No description."
        else .[0] end
    '
}

# The POSIX alarm survives exec and bounds osascript without a watchdog process.
if html=$(read_body | /usr/bin/perl -e 'alarm shift; exec @ARGV or die $!' 2 \
    /usr/bin/osascript -l JavaScript render-markdown.js "$PWD/vendor/marked/marked.umd.js" "$url"); then
    :
else
    case "$?" in
        142) html='<p>Preview timed out. Open the item on GitHub to read its description.</p>' ;;
        *) html='<p>Preview unavailable. Open the item on GitHub to read its description.</p>' ;;
    esac
fi

printf '%s' "$html" | /usr/bin/jq -Rs --rawfile page preview.html '
    {update: {ids: {
        preview: {text: ($page + .)}
    }}}
'
