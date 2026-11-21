#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

source ./cache.sh
url="${1:-}"
if [[ ! "$url" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/(pull|issues)/[0-9]+$ ]]; then
    url=
fi

read_body() {
    if [[ -z "$url" ]]; then
        printf 'Select an item to preview it.'
    elif [[ -r "$cache" ]]; then
        /usr/bin/jq -r --arg key "$identity" --arg url "$url" '
            ([select(.key == $key) | .results.items[] | select(.uid == $url)][0]) as $item
            | if $item == null then "Preview unavailable."
              elif ($item.body // "") == "" then "No description."
              else $item.body end
        ' < "$cache"
    else
        printf 'Preview unavailable.'
    fi
}

render_body() {
    if command -v pandoc >/dev/null; then
        pandoc -f gfm-raw_html -t html5 --lua-filter=preview.lua
    else
        /usr/bin/jq -Rs '"<p>Install Pandoc to render GitHub Markdown.</p><p style=\"white-space:pre-wrap\">\(. | @html)</p>"' -r
    fi
}

read_body | render_body | /usr/bin/jq -Rs --arg url "${url:-https://github.com/}" --rawfile page preview.html '
    {update: {ids: {
        preview: {text: ($page + "<base href=\"" + $url + "\">" + .)}
    }}}
'
