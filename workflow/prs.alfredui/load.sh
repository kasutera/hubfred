#!/bin/bash
set -euo pipefail

case "${dashboard_kind:-prs}" in
    prs)
        kind=prs noun=PRs
        relations='Authored|Review requested'
        cache_name=dashboard-v1.json
        ;;
    issues)
        kind=issues noun=Issues
        relations='Assigned|Authored|Mentioned|Commented'
        cache_name=issues-dashboard-v1.json
        ;;
    *) exit 2 ;;
esac

umask 077
cache_dir="${alfred_workflow_cache:-$HOME/Library/Caches/jp.kasutera.github-prs}"
/bin/mkdir -p "$cache_dir"

# Key by CLI credentials without sending a request or retaining the credentials.
identity=$(
    if [[ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]]; then
        printf 'token\0%s' "${GH_TOKEN:-${GITHUB_TOKEN:-}}"
    else
        printf 'hosts\0'
        hosts="${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/gh}/hosts.yml"
        if [[ -r "$hosts" ]]; then /bin/cat "$hosts"; fi
    fi | /usr/bin/shasum -a 256
)
cache="$cache_dir/$cache_name"
age=600
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
    if ! results=$(/bin/bash "$(dirname -- "$0")/../search.sh" dashboard "$kind") ||
        ! /usr/bin/jq -e '.cache and (.items | type == "array")' <<< "$results" >/dev/null; then
        if ((age < 600)); then printf '{}\n'; exit 0; fi
        /usr/bin/jq -n --arg noun "$noun" '{update:{ids:{prs:{placeholder:"Could not load GitHub \($noun)"}}}}'
        exit 0
    else
        temporary=$(/usr/bin/mktemp "$cache_dir/dashboard.XXXXXX")
        trap '/bin/rm -f "$temporary"' EXIT
        /usr/bin/jq -c --arg key "$identity" '{key: $key, results: .}' <<< "$results" > "$temporary"
        /bin/mv -f "$temporary" "$cache"
        if ((age < 600)) && [[ "$cached" == "$(/usr/bin/jq -c . <<< "$results")" ]]; then
            printf '{}\n'
            exit 0
        fi
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
            preview: (if (.body // "") == "" then "No description." else .body end),
            match: (["allitems", (.reasons[] | token), .match, (.labels[]?)] | join(" "))
        })), filter: {type: "basic", args: "match", match: "{value:category.selected.value} {value:query.text}", matchmode: "wordmatchanyorder"}}}
        } end)
    )}}
' <<< "$results"
