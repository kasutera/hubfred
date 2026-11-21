#!/bin/bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
mode="${1:-picker}"
kind="${2:-prs}"

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export GH_HOST=github.com GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1

message() {
    /usr/bin/jq -n --arg title "$1" --arg subtitle "$2" \
        '{items: [{title: $title, subtitle: $subtitle, valid: false}]}'
}

if ! command -v gh >/dev/null; then
    message 'GitHub CLI not found' 'Install gh, then sign in to github.com.'
    exit 0
fi

search_limit=1000
if [[ "$mode" == picker ]]; then search_limit=10; fi

search() {
    gh search "$kind" "$1" --state open --sort updated --limit "$search_limit" \
        --json "$fields"
}

fields=author,number,repository,title,updatedAt,url
case "$kind" in
    prs)
        noun=PRs
        fields+=,isDraft
        qualifiers=('author:@me' 'user-review-requested:@me')
        reasons='Authored|Review requested'
        states=(ready draft)
        ;;
    issues)
        noun=Issues
        qualifiers=('assignee:@me' 'author:@me' 'mentions:@me' 'commenter:@me')
        reasons='Assigned|Authored|Mentioned|Commented'
        states=(issue)
        if [[ "$mode" == dashboard ]]; then fields+=,labels; fi
        ;;
    *) exit 2 ;;
esac
[[ "$mode" != dashboard ]] || fields+=,body

results_dir=$(/usr/bin/mktemp -d)
trap '/bin/rm -r "$results_dir"' EXIT
files=() pids=()
for i in "${!qualifiers[@]}"; do
    files+=("$results_dir/$i.json")
    search "${qualifiers[$i]}" > "${files[$i]}" &
    pids+=("$!")
done

failed=0
for pid in "${pids[@]}"; do
    wait "$pid" || failed=1
done
if ((failed)); then
    message "Could not load GitHub $noun" 'Check the network and your GitHub CLI login.'
    exit 0
fi

icon_dir="${alfred_workflow_cache:-$HOME/Library/Caches/jp.kasutera.hubfred}/octicons-v5"
/bin/mkdir -p "$icon_dir"

# Color identifies the repository; Octicon shape identifies item kind and PR Draft state.
colors=(AC6B49 4269A5 A48332 B15F91 4E94B8 62636D)
pending=()
for i in "${!colors[@]}"; do
    for state in "${states[@]}"; do
        case "$state" in
            ready) asset=git-pull-request-16.svg ;;
            draft) asset=git-pull-request-draft-16.svg ;;
            issue) asset=issue-opened-16.svg ;;
        esac
        icon="$icon_dir/$i-$state"
        [[ -s "$icon.png" ]] && continue
        pending+=("$icon.svg")
        /usr/bin/sed -e 's/width="16" height="16"/width="64" height="64"/' \
            -e 's/viewBox="0 0 16 16"/viewBox="-1.142857 -1.142857 18.285714 18.285714"/' \
            -e "s/<svg /<svg fill=\"#${colors[$i]}\" /" "octicons/$asset" > "$icon.svg"
    done
done
if [[ -n "${pending[0]:-}" ]]; then
    /usr/bin/sips -s format png "${pending[@]}" --out "$icon_dir" >/dev/null
fi

/usr/bin/jq -s --arg icon_dir "$icon_dir" --argjson color_count "${#colors[@]}" \
    --argjson search_limit "$search_limit" --arg mode "$mode" --arg kind "$kind" --arg noun "$noun" --arg reasons "$reasons" '
    def repo_color:
        ascii_downcase | explode
        | reduce .[] as $c (0; (. * 31 + $c) % 2147483647)
        | . % $color_count;

    def local_timestamp:
        fromdateiso8601 | strflocaltime("%Y-%m-%d %H:%M");

    ($reasons | split("|")) as $relations
    | [to_entries[] | .key as $i | .value[] | . + {reason: $relations[$i]}]
    | group_by(.url)
    | map(.[0] + {reasons: (map(.reason) | unique)})
    | sort_by(.updatedAt) | reverse
    | (if $mode == "picker" then .[:$search_limit] else . end)
    | {items: map(.repository.nameWithOwner as $repo
        | (if $kind == "issues" then "issue" elif .isDraft then "draft" else "ready" end) as $state
        | {title,
           subtitle: "\($repo)#\(.number) · \(.author.login) · \(.updatedAt | local_timestamp) · \(.reasons | join(" · "))\(if .isDraft then " · Draft" else "" end)",
           match: "\(.title) \($repo) #\(.number) \(.number)",
           uid: .url,
           arg: .url,
           icon: {path: "\($icon_dir)/\($repo | repo_color)-\($state).png"}}
          + if $mode == "dashboard" then {body, reasons, labels: [.labels[]?.name]} else {} end)}
    | if .items == [] then
        {items: [{title: "No matching open \($noun)", subtitle: "No matching items on github.com", valid: false}]}
      else . end
    | . + {cache: {seconds: 30, loosereload: true}, skipknowledge: true}
' "${files[@]}"
