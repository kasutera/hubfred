#!/bin/bash
set -euo pipefail

cd -- "$(dirname -- "$0")"
source ./cache.sh
source ./cache-decisions.sh

case "${dashboard_kind:-prs}" in
    prs)
        kind=prs noun=PRs
        relations='Authored|Review requested'
        ;;
    issues)
        kind=issues noun=Issues
        relations='Assigned|Authored|Mentioned|Commented'
        ;;
    *) exit 2 ;;
esac
emit_failure() {
    /usr/bin/jq -n --arg noun "$noun" '
        {update:{ids:{
            prs:{
                placeholder: "Could not load GitHub \($noun)",
                data: {
                    type: "basic",
                    src: [],
                    filter: {type: "basic", args: "match",
                        match: "{value:category.selected.value} {value:query.text}",
                        matchmode: "wordmatchanyorder"}
                }
            },
            preview: {text: "<!doctype html><html><body></body></html>"}
        }}}
    '
}

if [[ "$dashboard_auth_resolved" != true ]]; then
    emit_failure
    exit 0
fi

umask 077
/bin/mkdir -p "$cache_dir"

read_cache_state() {
    age=600
    cached=
    cached_identity=
    cached_digest=
    local columns='unixepoch() - saved_at, digest' state
    # The refresh checks only metadata. Preload reads rows, never descriptions.
    if [[ "${1:-}" == cached ]]; then columns+=', list'; fi
    if [[ -s "$cache" ]] && state=$(cache_sqlite -readonly -separator $'\n' "$cache" \
        "SELECT $columns FROM dashboard WHERE identity = '$identity';" 2>/dev/null) &&
        [[ -n "$state" ]]; then
        {
            IFS= read -r age
            IFS= read -r cached_digest
            IFS= read -r cached || :
        } <<< "$state"
        cached_identity=$identity
    fi
}

read_cache_state "${1:-}"

configure=false
if [[ "${1:-}" == cached ]]; then
    configure=true
    if cache_should_show_cached "$age" "$cached_identity" "$identity"; then results="$cached"; else results='{"items":[]}'; fi
else
    # Before fetching, a matching entry younger than 30 seconds suppresses a refresh.
    if cache_should_skip_fetch "$age" "$cached_identity" "$identity"; then printf '{}\n'; exit 0; fi
    search_identity=$identity
    search_token=$dashboard_auth_token
    search_failed=false
    if results=$(GH_TOKEN="$search_token" /bin/bash ../search.sh dashboard "$kind") &&
        /usr/bin/jq -e '.cache and (.items | type == "array")' <<< "$results" >/dev/null; then
        :
    else
        search_failed=true
    fi

    # After fetching, re-resolve identity before fallback, display, or cache decisions.
    resolve_dashboard_auth
    if [[ "$dashboard_auth_resolved" != true || "$identity" != "$search_identity" ]]; then
        emit_failure
        exit 0
    fi
    if [[ "$search_failed" == true ]]; then
        if cache_should_reuse_after_failure "$age" "$cached_identity" "$identity" "$search_failed"; then printf '{}\n'; else emit_failure; fi
        exit 0
    fi

    digest=$(printf '%s' "$results" | /usr/bin/shasum -a 256)
    temporary=$(/usr/bin/mktemp "$cache_dir/dashboard.XXXXXX")
    trap '/bin/rm -f "$temporary" "$temporary-journal"' EXIT
    # Keep both tables in one snapshot so readers never see a mixed refresh.
    /usr/bin/jq -r --arg key "$identity" --arg digest "$digest" '
        def literal: "\u0027" + gsub("\u0027"; "\u0027\u0027") + "\u0027";
        ([
            "BEGIN;",
            "CREATE TABLE dashboard (identity TEXT NOT NULL, saved_at INTEGER NOT NULL, digest TEXT NOT NULL, list TEXT NOT NULL);",
            "CREATE TABLE bodies (url TEXT PRIMARY KEY, body TEXT NOT NULL) WITHOUT ROWID;",
            "INSERT INTO dashboard VALUES (\($key | literal), unixepoch(), \($digest | literal), \({items: [.items[] | del(.body)]} | @json | literal));"
        ][]),
        (.items[] | select(.uid) |
            "INSERT INTO bodies VALUES (\(.uid | literal), \((.body // "") | @json | literal));"),
        "COMMIT;"
    ' <<< "$results" | cache_sqlite "$temporary"
    /bin/mv -f "$temporary" "$cache"
    if cache_should_show_cached "$age" "$cached_identity" "$identity" && [[ "$cached_digest" == "$digest" ]]; then
        printf '{}\n'
        exit 0
    fi
fi

/usr/bin/jq --arg noun "$noun" --arg relations "$relations" --argjson configure "$configure" '
    def token: "relation" + (ascii_downcase | gsub(" "; ""));

    [.items[] | select(.arg)] as $rows
    | {update: {ids: (
        (if $configure then {category: {items: (
            [{text: "All \($noun)", value: "allitems"}] +
            ($relations | split("|") | map({text: ., value: token}))
        ), selected: "allitems"}} else {} end)
        + (if $configure and .items == [] then {} else {
        prs: {placeholder: "No matching open \($noun)", data: {type: "basic", src: ($rows | map({
            uid,
            "title.text": .title,
            "subtitle.text": ((.labels // [] | if length > 0 then "Labels: \(join(", ")) · " else "" end) + .subtitle),
            "glyph.image": {type: "file", src: .icon.path},
            match: (["allitems", (.reasons[] | token), .match, (.labels[]?)] | join(" "))
        })), filter: {type: "basic", args: "match", match: "{value:category.selected.value} {value:query.text}", matchmode: "wordmatchanyorder"}}}
        } end)
    )}}
' <<< "$results"
