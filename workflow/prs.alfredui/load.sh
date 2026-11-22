#!/bin/bash
set -euo pipefail

cd -- "$(dirname -- "$0")"
source ./cache.sh

case "${dashboard_kind:-prs}" in
    prs)
        kind=prs noun=PRs
        relations='Authored|Review requested'
        ;;
    issues)
        kind=issues noun=Issues
        relations='Assigned|Authored|Mentioned|Commented'
        ;;
    all)
        kind=all noun='PRs and issues'
        relations='Assigned|Authored|Mentioned|Commented|Review requested'
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

state=metadata
if [[ "${1:-}" == cached ]]; then state=list; fi
cache_read "$state"

configure=false
if [[ "${1:-}" == cached ]]; then
    configure=true
    if cache_should_show_cached "$age" "$cached_identity" "$identity"; then results="$cached"; else results='{"items":[]}'; fi
else
    if cache_should_skip_fetch "$age" "$cached_identity" "$identity"; then printf '{}\n'; exit 0; fi
    refresh_status=0
    cache_refresh_search ../search.sh dashboard "$kind" || refresh_status=$?
    case "$refresh_status" in
        0) ;;
        1)
            if cache_should_reuse_after_failure "$age" "$cached_identity" "$identity" true; then
                printf '{}\n'
            else
                emit_failure
            fi
            exit 0
            ;;
        *) emit_failure; exit 0 ;;
    esac

    digest=$(cache_digest)
    cache_write "$digest"
    if cache_should_show_cached "$age" "$cached_identity" "$identity" && [[ "$cached_digest" == "$digest" ]]; then
        printf '{}\n'
        exit 0
    fi
fi

/usr/bin/jq --arg noun "$noun" --arg kind "$kind" --arg relations "$relations" --argjson configure "$configure" '
    def token: "relation" + (ascii_downcase | gsub(" "; ""));

    [.items[] | select(.arg)] as $rows
    | {update: {ids: (
        (if $configure then {category: {items: (
            [{text: "All \($noun)", value: "allitems"}] +
            (if $kind == "all" then [{text: "PRs", value: "kindpr"}, {text: "Issues", value: "kindissue"}] else [] end) +
            ($relations | split("|") | map({text: ., value: token}))
        ), selected: "allitems"}} else {} end)
        + (if $configure and .items == [] then {} else {
        prs: {placeholder: "No matching open \($noun)", data: {type: "basic", src: ($rows | map({
            uid,
            "title.text": .title,
            "subtitle.text": ((.labels // [] | if length > 0 then "Labels: \(join(", ")) · " else "" end) + .subtitle),
            "glyph.image": {type: "file", src: .icon.path},
            match: (["allitems", (if $kind == "all" then .kind else empty end), (.reasons[] | token), .match, (.labels[]?)] | join(" "))
        })), filter: {type: "basic", args: "match", match: "{value:category.selected.value} {value:query.text}", matchmode: "wordmatchanyorder"}}}
        } end)
    )}}
' <<< "$results"
