#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

row="${1:-null}"
body=$(/usr/bin/jq -r '.preview // "Select an item to preview it."' <<< "${row:-null}")
if command -v pandoc >/dev/null && html=$(printf '%s' "$body" \
    | pandoc -f gfm-raw_html -t html5 --lua-filter=preview.lua); then
    :
else
    html=$(/usr/bin/jq -nr --arg body "$body" \
        '"<p>Install Pandoc to render GitHub Markdown.</p><p style=\"white-space:pre-wrap\">\($body | @html)</p>"')
fi

/usr/bin/jq -n --argjson row "${row:-null}" --arg html "$html" --rawfile page preview.html '
    ($row.uid // "" | if test("^https://github\\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/(pull|issues)/[0-9]+$") then . else "https://github.com/" end) as $url
    | {update: {ids: {
        preview: {text: ($page + "<base href=\"" + $url + "\">" + $html)}
    }}}
'
