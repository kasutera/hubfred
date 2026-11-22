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

emit_picker() {
    /usr/bin/perl -MJSON::PP -MUnicode::Normalize=NFD -MEncode=decode -e '
        my ($query, $rerun, $identity, $mode) = @ARGV;
        $query = NFD(decode("UTF-8", $query));
        local $/;
        my $json = JSON::PP->new->utf8;
        my $output = $json->decode(<STDIN>);
        if (length $query) {
            my $fold = $query !~ /\pM/;
            my @terms = map { qr/(?:^|\s)\Q$_\E/i } split " ", $query;
            my @matches;
            for my $item (@{$output->{items}}) {
                next unless $item->{arg};
                my $repo = (split m{/}, $item->{uid})[4];
                my $text = "$item->{match} $repo";
                $text = NFD($text);
                $text =~ s/\pM//g if $fold;
                next if grep { $text !~ $_ } @terms;
                push @matches, {map { $_ => $item->{$_} } qw(title subtitle uid arg icon)};
                last if @matches == 10;
            }
            push @matches, {
                title => $rerun eq "true" ? "Searching GitHub\x{2026}" : "No matching open items",
                valid => JSON::PP::false
            } unless @matches;
            $output = {items => \@matches};
        }
        $output->{skipknowledge} = JSON::PP::true;
        if ($rerun eq "true") {
            $output->{rerun} = length($query) ? 0.3 : 0.1;
            $output->{variables} = {hubfred_refresh_identity => $identity, hubfred_refresh_mode => $mode};
        }
        print $json->encode($output), "\n";
    ' "$query" "$rerun" "$identity" "$cache_mode" <<< "$results"
}

if [[ "$mode" == cached-picker ]]; then
    cache_mode=picker
    query=${3:-}
    if [[ "$query" =~ ^[[:space:]]*$ ]]; then
        query=
    else
        # Filter before taking ten, using the same broad snapshot as the dashboard.
        cache_mode=dashboard
    fi
    cache_kind=$kind
    source ./prs.alfredui/cache.sh

    if ! command -v gh >/dev/null; then
        message 'GitHub CLI not found' 'Install gh, then sign in to github.com.'
        exit 0
    fi
    if [[ "$dashboard_auth_resolved" != true ||
          ( -n "${hubfred_refresh_identity:-}" && "$hubfred_refresh_identity" != "$identity" ) ]]; then
        message 'Could not load GitHub results' 'Check your GitHub CLI login and reopen the picker.'
        exit 0
    fi

    cache_read list
    rerun=false
    refreshing=false
    if [[ "${hubfred_refresh_mode:-}" == "$cache_mode" ]]; then refreshing=true; fi
    if cache_should_skip_fetch "$age" "$cached_identity" "$identity"; then
        results=$cached
    elif [[ "$refreshing" == false ]] && cache_should_show_cached "$age" "$cached_identity" "$identity"; then
        # Alfred keeps these rows visible while the one-shot rerun fetches replacements.
        results=$cached
        rerun=true
    elif [[ "$refreshing" == false && -n "$query" ]]; then
        results='{"items":[]}'
        rerun=true
    else
        refresh_status=0
        cache_refresh_search ./search.sh "$cache_mode" "$kind" || refresh_status=$?
        case "$refresh_status" in
            0)
                digest=
                if [[ "$cache_mode" == dashboard ]]; then digest=$(cache_digest); fi
                cache_write "$digest"
                ;;
            1)
                if cache_should_reuse_after_failure "$age" "$cached_identity" "$identity" true; then
                    results=$cached
                elif [[ -n "$query" || -z "$results" ]]; then
                    message 'Could not load GitHub results' 'Check the network and your GitHub CLI login.'
                    exit 0
                fi
                ;;
            *) message 'Could not load GitHub results' 'GitHub CLI login changed. Reopen the picker.'; exit 0 ;;
        esac
    fi
    emit_picker
    exit 0
fi

if ! command -v gh >/dev/null; then
    message 'GitHub CLI not found' 'Install gh, then sign in to github.com.'
    exit 1
fi

search_limit=1000
if [[ "$mode" == picker ]]; then search_limit=10; fi

pr_queries=('prs:author:@me' 'prs:user-review-requested:@me')
issue_queries=('issues:assignee:@me' 'issues:author:@me' 'issues:mentions:@me' 'issues:commenter:@me')
pr_reasons='Authored|Review requested'
issue_reasons='Assigned|Authored|Mentioned|Commented'
case "$kind" in
    prs)
        noun=PRs
        queries=("${pr_queries[@]}")
        reasons=$pr_reasons
        states=(ready draft)
        ;;
    issues)
        noun=Issues
        queries=("${issue_queries[@]}")
        reasons=$issue_reasons
        states=(issue)
        ;;
    all)
        noun='PRs and issues'
        queries=("${pr_queries[@]}" "${issue_queries[@]}")
        reasons="$pr_reasons|$issue_reasons"
        states=(ready draft issue)
        ;;
    *) exit 2 ;;
esac

search() {
    local query_kind=${1%%:*} fields=author,number,repository,title,updatedAt,url
    if [[ "$query_kind" == prs ]]; then fields+=,isDraft; fi
    if [[ "$mode" == dashboard ]]; then
        fields+=,body
        if [[ "$kind" != prs ]]; then fields+=,labels; fi
    fi
    gh search "$query_kind" "${1#*:}" --state open --sort updated --limit "$search_limit" \
        --json "$fields"
}

results_dir=$(/usr/bin/mktemp -d)
trap '/bin/rm -r "$results_dir"' EXIT
files=() pids=()
for i in "${!queries[@]}"; do
    files+=("$results_dir/$i.json")
    search "${queries[$i]}" > "${files[$i]}" &
    pids+=("$!")
done

failed=0
for pid in "${pids[@]}"; do
    wait "$pid" || failed=1
done
if ((failed)); then
    message "Could not load GitHub $noun" 'Check the network and your GitHub CLI login.'
    exit 1
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
    --argjson search_limit "$search_limit" --arg mode "$mode" --arg noun "$noun" --arg reasons "$reasons" \
    -f search-results.jq "${files[@]}"
