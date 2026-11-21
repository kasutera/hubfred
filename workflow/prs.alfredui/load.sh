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

age=600
cached=
if [[ -s "$cache" ]]; then
    cached=$(/usr/bin/jq -c --arg key "$identity" 'select(.key == $key) | .results' "$cache") || cached=
    if [[ -n "$cached" ]]; then
        mtime=$(/usr/bin/stat -f %m "$cache")
        age=$(( $(/bin/date +%s) - mtime ))
    fi
fi

configure=false
if [[ "${1:-}" == cached ]]; then
    configure=true
    if ((age < 600)); then results="$cached"; else results='{"items":[]}'; fi
else
    if ((age < 30)); then printf '{}\n'; exit 0; fi
    search_identity=$identity
    search_token=$dashboard_auth_token
    search_failed=false
    if results=$(GH_TOKEN="$search_token" /bin/bash ../search.sh dashboard "$kind") &&
        /usr/bin/jq -e '.cache and (.items | type == "array")' <<< "$results" >/dev/null; then
        :
    else
        search_failed=true
    fi

    resolve_dashboard_auth
    if [[ "$dashboard_auth_resolved" != true || "$identity" != "$search_identity" ]]; then
        emit_failure
        exit 0
    fi
    if [[ "$search_failed" == true ]]; then
        if ((age < 600)); then printf '{}\n'; else emit_failure; fi
        exit 0
    fi

    temporary=$(/usr/bin/mktemp "$cache_dir/dashboard.XXXXXX")
    trap '/bin/rm -f "$temporary"' EXIT
    /usr/bin/jq -c --arg key "$identity" '{key: $key, results: .}' <<< "$results" > "$temporary"
    /bin/mv -f "$temporary" "$cache"
    if ((age < 600)) && [[ "$cached" == "$(/usr/bin/jq -c . <<< "$results")" ]]; then
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
