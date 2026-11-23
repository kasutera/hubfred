#!/bin/bash
set -euo pipefail

workflow_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$workflow_dir/prs.alfredui/cache.sh"
source "$workflow_dir/search-core.sh"
umask 077
session=
picker_temp_file=
picker_cleanup() {
    [[ -z "${session:-}" ]] || /bin/rm -rf -- "$session"
    [[ -z "${picker_temp_file:-}" ]] || /bin/rm -f -- "$picker_temp_file" "$picker_temp_file.filtered"
}
trap picker_cleanup EXIT

picker_temp_root() {
    local root=${TMPDIR:-/tmp}
    case "$root" in
        /*) ;;
        *) root="$PWD/$root" ;;
    esac
    root=${root%/}
    [[ -n "$root" ]] || root=/
    printf '%s\n' "$root"
}

picker_temp_template() {
    local root
    root=$(picker_temp_root)
    if [[ "$root" == / ]]; then
        printf '/%s' "$1"
    else
        printf '%s/%s' "$root" "$1"
    fi
}


picker_message() {
    /usr/bin/jq -n --arg title "$1" --arg subtitle "${2:-}" \
        '{items: [{title: $title, subtitle: $subtitle, valid: false}]}'
}

picker_noun() {
    case "$1" in
        prs) printf 'PRs' ;;
        issues) printf 'Issues' ;;
        all) printf 'PRs and issues' ;;
        *) printf 'items' ;;
    esac
}

picker_query_is_blank() {
    /usr/bin/perl -MEncode=decode_utf8 -e '
        my $value = decode_utf8($ARGV[0]);
        $value =~ s/\A\s+|\s+\z//g;
        print length($value) ? "0\n" : "1\n";
    ' -- "$1"
}

picker_filter() {
    local query=$1 input_file=$2
    /usr/bin/perl -MJSON::PP -MEncode=decode_utf8 -MUnicode::Normalize=NFD -e '
        use strict;
        use warnings;
        use feature "fc";
        my $query = decode_utf8($ARGV[0]);
        my $json = do { local $/; <STDIN> };
        my $data = JSON::PP->new->utf8->decode($json);
        my $normalized_query = NFD($query);
        my @terms = grep { length } split /\s+/, fc($normalized_query);
        my $fold_marks = $normalized_query !~ /\p{M}/;
        my @matches;
        ITEM: for my $item (@{$data->{items} // []}) {
            next unless ref($item) eq "HASH" && defined($item->{arg}) && length($item->{arg});
            my $match = defined($item->{match}) ? $item->{match} : "";
            my $text = NFD(fc($match));
            my $repository = "";
            if (defined($item->{uid}) && $item->{uid} =~ m{\Ahttps://github\.com/[^/]+/([^/]+)}) {
                $repository = fc($1);
            }
            if ($fold_marks) {
                $text =~ s/\p{M}//g;
                $repository =~ s/\p{M}//g;
            }
            for my $term (@terms) {
                my $found = 0;
                for my $value ($text, $repository) {
                    for my $word (split /\s+/, $value) {
                        if (index($word, $term) == 0) {
                            $found = 1;
                            last;
                        }
                    }
                    last if $found;
                }
                next ITEM unless $found;
            }
            push @matches, $item;
            last if @matches == 10;
        }
        print JSON::PP->new->utf8->encode({items => \@matches});
    ' -- "$query" < "$input_file"
}

picker_response() {
    local rows_file=$1 filtered=$2 rerun=$3 refresh_identity=$4 refresh_mode=$5 noun=$6
    local delay=0.1
    if [[ "$filtered" == true ]]; then delay=0.3; fi
    /usr/bin/jq -n --slurpfile snapshot "$rows_file" --arg noun "$noun" \
        --argjson filtered "$filtered" --argjson rerun "$rerun" \
        --argjson delay "$delay" --arg identity "$refresh_identity" --arg mode "$refresh_mode" '
        ([ $snapshot[0].items[]? | select((.arg // "") != "") | {
            title, subtitle, uid, arg, icon
        } ][:10]) as $rows
        | {
            items: (if ($rows | length) > 0 then $rows
                elif $filtered then [{title: (if $rerun then "Searching GitHub…" else "No matching open items" end), valid: false}]
                else [{title: "No matching open \($noun)", subtitle: "No matching items on github.com", valid: false}]
                end),
            skipknowledge: true
          }
        | if $rerun then . + {rerun: $delay, variables: {
            hubfred_refresh_identity: $identity, hubfred_refresh_mode: $mode
          }} else . end
    '
}

picker_fetch() {
    local fetch_limit=$1 fetch_cutoff=$2 rounds=0
    session=$(/usr/bin/mktemp -d "$(picker_temp_template 'hubfred-picker.XXXXXXXX')") || return 1
    if ! search_first "$fetch_limit" "$fetch_cutoff" > "$session/results.json"; then
        return 1
    fi
    if ! /usr/bin/jq -e 'type == "object" and (.items | type == "array")' \
        "$session/results.json" >/dev/null 2>&1; then
        return 1
    fi
    while /usr/bin/jq -e '.more == true' "$session/results.json" >/dev/null 2>&1; do
        rounds=$((rounds + 1))
        (( rounds <= 10 )) || return 1
        if ! search_more "$fetch_limit" > "$session/next.json"; then
            return 1
        fi
        if ! /usr/bin/jq -e 'type == "object" and (.items | type == "array")' \
            "$session/next.json" >/dev/null 2>&1; then
            return 1
        fi
        /bin/mv -f -- "$session/next.json" "$session/results.json" || return 1
    done
    return 0
}

picker_main() {
    local requested_kind=${1:-} query=${2:-} blank filtered read_mode cache_mode fetch_limit expected_identity noun refreshing=false
    if ! cache_init "$requested_kind"; then
        picker_message 'Could not load GitHub results' 'Check your GitHub CLI login and reopen the picker.'
        return 0
    fi
    noun=$(picker_noun "$kind")
    if [[ -z "$gh_path" ]]; then
        picker_message 'GitHub CLI not found' 'Install gh, then sign in to github.com.'
        return 0
    fi
    if ! cache_credential; then
        picker_message 'Could not load GitHub results' 'Check your GitHub CLI login and reopen the picker.'
        return 0
    fi
    if [[ -n "${hubfred_refresh_identity:-}" && "$hubfred_refresh_identity" != "$identity" ]]; then
        picker_message 'Could not load GitHub results' 'GitHub CLI login changed. Reopen the picker.'
        return 0
    fi

    blank=$(picker_query_is_blank "$query") || return 1
    filtered=true
    read_mode=broad
    cache_mode=dashboard
    fetch_limit=1000
    if [[ "$blank" == 1 ]]; then
        filtered=false
        query=
        read_mode=picker
        cache_mode=picker
        fetch_limit=10
    fi
    cache_read "$read_mode" || :
    local cached_rows=$cached cached_age=$age
    expected_identity=$identity
    if [[ "${hubfred_refresh_mode:-}" == "$cache_mode" ]]; then
        refreshing=true
    fi

    picker_temp_file=$(/usr/bin/mktemp "$(picker_temp_template 'hubfred-picker-cache.XXXXXXXX')") || return 1
    printf '%s\n' "$cached_rows" > "$picker_temp_file" || return 1
    local rows_file=$picker_temp_file

    if (( cached_age < CACHE_FRESH_SECONDS )); then
        if [[ "$filtered" == true ]]; then
            picker_filter "$query" "$rows_file" > "$rows_file.filtered" || return 1
            /bin/mv -f -- "$rows_file.filtered" "$rows_file" || return 1
        fi
        picker_response "$rows_file" "$filtered" false "$expected_identity" "$cache_mode" "$noun"
        return 0
    fi
    if [[ "$refreshing" != true ]] && (( cached_age < CACHE_STALE_SECONDS )); then
        if [[ "$filtered" == true ]]; then
            picker_filter "$query" "$rows_file" > "$rows_file.filtered" || return 1
            /bin/mv -f -- "$rows_file.filtered" "$rows_file" || return 1
        fi
        picker_response "$rows_file" "$filtered" true "$expected_identity" "$cache_mode" "$noun"
        return 0
    fi
    if [[ "$refreshing" != true && "$filtered" == true ]]; then
        printf '{"items":[]}\n' > "$rows_file"
        picker_response "$rows_file" true true "$expected_identity" "$cache_mode" "$noun"
        return 0
    fi

    if ! picker_fetch "$fetch_limit" ''; then
        if ! cache_credential || [[ "$identity" != "$expected_identity" ]]; then
            picker_message 'Could not load GitHub results' 'GitHub CLI login changed. Reopen the picker.'
            return 0
        fi
        cache_read "$read_mode" || :
        if (( age < CACHE_STALE_SECONDS )); then
            printf '%s\n' "$cached" > "$rows_file" || return 1
            if [[ "$filtered" == true ]]; then
                picker_filter "$query" "$rows_file" > "$rows_file.filtered" || return 1
                /bin/mv -f -- "$rows_file.filtered" "$rows_file" || return 1
            fi
            picker_response "$rows_file" "$filtered" false "$expected_identity" "$cache_mode" "$noun"
        else
            picker_message 'Could not load GitHub results' 'Check your GitHub CLI login and reopen the picker.'
        fi
        return 0
    fi
    if ! cache_credential || [[ "$identity" != "$expected_identity" ]]; then
        picker_message 'Could not load GitHub results' 'GitHub CLI login changed. Reopen the picker.'
        return 0
    fi
    if [[ "$filtered" != true ]]; then
        if ! /usr/bin/jq -c '{items: [.items[:10][]]}' "$session/results.json" > "$session/limited.json"; then
            picker_message 'Could not load GitHub results' 'Check your GitHub CLI login and reopen the picker.'
            return 0
        fi
        /bin/mv -f -- "$session/limited.json" "$session/results.json" || return 1
    fi
    if ! cache_write "$read_mode" "$session/results.json"; then
        picker_message 'Could not load GitHub results' 'Check your GitHub CLI login and reopen the picker.'
        return 0
    fi
    if [[ "$filtered" == true ]]; then
        picker_filter "$query" "$session/results.json" > "$rows_file" || return 1
    else
        /bin/cp "$session/results.json" "$rows_file" || return 1
    fi
    picker_response "$rows_file" "$filtered" false "$expected_identity" "$cache_mode" "$noun"
}

case "${1:-}" in
    cached-picker)
        [[ $# -eq 3 ]] || { picker_message 'Could not load GitHub results' 'Check your GitHub CLI login and reopen the picker.'; exit 0; }
        picker_main "$2" "$3"
        ;;
    *)
        printf 'Unknown search action\n' >&2
        exit 2
        ;;
esac
