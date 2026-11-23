#!/bin/bash
set -euo pipefail

cd -- "$(dirname -- "$0")"
workflow_dir="${PWD%/*}"
source ./cache.sh
source ../search-core.sh
umask 077

phase=${1:-}
session=${dashboard_session:-}
temp_root=${TMPDIR:-/tmp}
temp_root=${temp_root%/}
# Only accept a private session directly under the system temporary directory.
if [[ "${session%/*}" != "$temp_root" || ! "${session##*/}" =~ ^hubfred-dashboard\.[[:alnum:]]+$ ||
      ! -d "$session" || -L "$session" || ! -O "$session" ]]; then
    session=
fi
cleanup() {
    if [[ -n "$session" ]]; then /bin/rm -rf -- "$session"; fi
}

case "$phase" in
    quit) cleanup; exit 0 ;;
    cached|preview) ;;
    first|more|save)
        if [[ -z "$session" || ! -r "$session/scope" ]]; then printf '{}\n'; exit 0; fi
        trap cleanup EXIT
        ;;
    *) exit 2 ;;
esac

kind=${dashboard_kind:-prs}
case "$kind" in
    prs) noun=PRs relations='Authored|Review requested' ;;
    issues) noun=issues relations='Assigned|Authored|Mentioned|Commented' ;;
    all) noun='PRs and issues' relations='Assigned|Authored|Mentioned|Commented|Review requested' ;;
    *) exit 2 ;;
esac

blank_html='<!doctype html><html><body></body></html>'
preview_response() {
    /usr/bin/jq -Rs --arg url "$url" \
        '{variables:{dashboard_selection:$url}, update:{ids:{preview:{text:.}}}}'
}

preview() {
    url=${2:-}
    if [[ ! "$url" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/(pull|issues)/[0-9]+$ ]]; then
        url=
        printf '%s' "$blank_html" | preview_response
        return
    fi
    local unavailable='<p>Preview unavailable. Open the item on GitHub to read its description.</p>'
    case "${3:-}" in
        pending) printf '%s' '<!doctype html><meta charset=utf-8><p>Preparing preview…</p>' | preview_response; return ;;
        unavailable) printf '%s' "$unavailable" | preview_response; return ;;
    esac
    local body_json= html
    if cache_init "$kind" && cache_credential; then body_json=$(cache_body "$url") || body_json=; fi
    # The POSIX alarm survives exec and bounds osascript without a watchdog process.
    if html=$(printf '%s' "$body_json" | /usr/bin/jq -js '
        if length == 0 then "Preview unavailable."
        elif .[0] == "" then "No description."
        else .[0] end
    ' | /usr/bin/perl -e 'alarm shift; exec @ARGV or die $!' 2 \
        /usr/bin/osascript -l JavaScript render-markdown.js "$PWD/vendor/marked/marked.umd.js" "$url"); then
        :
    else
        case "$?" in
            142) html='<p>Preview timed out. Open the item on GitHub to read its description.</p>' ;;
            *) html=$unavailable ;;
        esac
    fi
    if [[ -r preview.html ]]; then
        { /bin/cat preview.html; printf '%s' "$html"; } | preview_response
    else
        printf '%s' "$unavailable" | preview_response
    fi
}

if [[ "$phase" == preview ]]; then preview "$@"; exit 0; fi

emit_failure() {
    /usr/bin/jq -n --arg noun "$noun" --arg html "$blank_html" '
        {update: {relayout: true, ids: {
            prs: {placeholder: "Could not load GitHub \($noun)", data: {
                type: "basic", src: [], filter: {type: "basic", args: "match",
                    match: "{value:category.selected.value} {value:query.text}", matchmode: "wordmatchanyorder"}
            }},
            loadstatus: {text: ""}, preview: {text: $html}
        }}}
    '
}

display() {
    local state=$1 status=${2:-} next=${3:-} configure=false
    if [[ "$phase" == cached ]]; then configure=true; fi
    /usr/bin/jq --arg noun "$noun" --arg kind "$kind" --arg relations "$relations" \
        --arg state "$state" --arg status "$status" --arg next "$next" --arg session "$session" \
        --arg cutoff "$cutoff" --argjson configure "$configure" '
        def token: "relation" + (ascii_downcase | gsub(" "; ""));
        [.items[]? | select((.arg // "") != "")
            | select($cutoff == "" or ((.updatedAt // "")[0:19] >= $cutoff[0:19]))
            | {
                uid, previewState: $state, "title.text": .title,
                "subtitle.text": ((.labels // [] | if length > 0 then "Labels: \(join(", ")) · " else "" end) + .subtitle),
                "glyph.image": {type: "file", src: .icon.path},
                match: (["allitems", (if $kind == "all" then .kind // empty else empty end), (.reasons[]? | token), .match, (.labels[]?)] | join(" "))
            }] as $rows
        | {update: {relayout: ($configure | not), ids: {loadstatus: {text: $status}}}}
        | if $configure then
            .variables.dashboard_session = $session
            | .update.ids.category = {selected: "allitems", items: (
                [{text: "All \($noun)", value: "allitems"}] +
                (if $kind == "all" then [{text: "PRs", value: "kindpr"}, {text: "Issues", value: "kindissue"}] else [] end) +
                ($relations | split("|") | map({text: ., value: token}))
            )}
          else . end
        | if $next != "" then .pulse = {src: "load.sh", args: [$next], now: true} else . end
        | if $configure and $rows == [] then . else
            .update.ids.prs = {
                placeholder: (if $status == "" then "No matching open \($noun)" else $status end),
                data: {type: "basic", src: $rows, filter: {type: "basic", args: "match",
                    match: "{value:category.selected.value} {value:query.text}", matchmode: "wordmatchanyorder"}}
            }
            | if $configure then . else .update.ids.prs.select = "{var:dashboard_selection}" end
          end
    '
}

picker_fallback() {
    cache_read picker || :
    if (( age < CACHE_STALE_SECONDS )); then
        /usr/bin/jq -c --arg cutoff "$cutoff" --argjson limit "$limit" '
            {items: ([.items[]? | select((.arg // "") != "")
                | select($cutoff == "" or ((.updatedAt // "")[0:19] >= $cutoff[0:19]))][: $limit])}
        ' <<< "$cached"
    else
        printf '{"items":[]}\n'
    fi
}

if ! cache_init "$kind" || ! cache_credential; then
    emit_failure
    exit 0
fi

if [[ "$phase" == cached ]]; then
    session=
    cache_read dashboard || :
    rows=$cached state=ready
    if (( age >= CACHE_FRESH_SECONDS )); then
        if ! session=$(/usr/bin/mktemp -d "$temp_root/hubfred-dashboard.XXXXXXXX"); then emit_failure; exit 0; fi
        trap cleanup EXIT
        if ! printf '%s\n' "$identity" "$kind:$limit:$days" "$cutoff" > "$session/scope"; then emit_failure; exit 0; fi
    fi
    if (( age >= CACHE_STALE_SECONDS )); then
        rows=$(picker_fallback) state=pending
    fi
    display "$state" <<< "$rows"
    trap - EXIT
    exit 0
fi

{
    IFS= read -r session_identity
    IFS= read -r session_settings
    IFS= read -r session_cutoff
} < "$session/scope"
if [[ "$session_identity" != "$identity" || "$session_settings" != "$kind:$limit:$days" ]]; then
    emit_failure
    exit 0
fi

result="$session/result.json"
if [[ "$phase" == save ]]; then
    if [[ ! -r "$result" ]]; then emit_failure; exit 0; fi
    if cache_write dashboard "$result"; then
        display ready < "$result"
    else
        display unavailable 'Could not save results' < "$result"
    fi
    exit 0
fi

ok=true
if [[ "$phase" == first ]]; then
    search_first "$limit" "$session_cutoff" > "$session/next.json" || ok=false
else
    search_more "$limit" > "$session/next.json" || ok=false
fi
if ! cache_credential || [[ "$session_identity" != "$identity" ]]; then
    emit_failure
    exit 0
fi
if ! $ok; then
    if [[ "$phase" == more && -r "$result" ]]; then
        display unavailable 'Could not load more results' < "$result"
    else
        cache_read dashboard || :
        if (( age < CACHE_STALE_SECONDS )); then
            printf '{}\n'
        else
            fallback=$(picker_fallback)
            if /usr/bin/jq -e '.items | length > 0' <<< "$fallback" >/dev/null; then
                display unavailable "Could not load GitHub $noun" <<< "$fallback"
            else
                emit_failure
            fi
        fi
    fi
    exit 0
fi

/bin/mv -f "$session/next.json" "$result"
if /usr/bin/jq -e '.more == true' "$result" >/dev/null; then
    display pending 'Loading more results…' more < "$result"
else
    display pending '' save < "$result"
fi
trap - EXIT
