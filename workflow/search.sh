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

search() {
    gh search "$kind" "$1" --state open --sort updated --limit 1000 \
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

icon_dir="${alfred_workflow_cache:-$HOME/Library/Caches/jp.kasutera.github-prs}/octicons-v1"
/bin/mkdir -p "$icon_dir"

# Both states use the repository's color; the branch shape carries the state.
colors=(448C70 397AB8 8D64B8 B26835 BF5378 33868E 687FB5 A34F44 7D853C A25BAD 537E4C 8C715A)
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
            -e "s/<path /<path fill=\"#${colors[$i]}\" /" "octicons/$asset" > "$icon.svg"
    done
done
if [[ -n "${pending[0]:-}" ]]; then
    /usr/bin/sips -s format png "${pending[@]}" --out "$icon_dir" >/dev/null
fi

/usr/bin/jq -s --arg icon_dir "$icon_dir" --argjson color_count "${#colors[@]}" \
    --arg mode "$mode" --arg kind "$kind" --arg noun "$noun" --arg reasons "$reasons" '
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
