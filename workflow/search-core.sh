#!/bin/bash

# This file is sourced by the workflow entry points. Keep runtime work inside
# the public functions below so sourcing it does not change the caller's state.

_hubfred_search_categories() {
    case "$1" in
        prs)
            hubfred_search_qualifiers=(author user-review-requested)
            ;;
        issues)
            hubfred_search_qualifiers=(assignee author mentions commenter)
            ;;
        all)
            hubfred_search_qualifiers=(author user-review-requested assignee author mentions commenter)
            ;;
        *)
            printf 'Invalid GitHub search kind\n' >&2
            return 1
            ;;
    esac
}

_hubfred_search_limit() {
    local value="${1:-}"
    case "$value" in
        ''|*[!0-9]*)
            printf 'Invalid GitHub search limit\n' >&2
            return 1
            ;;
    esac
    while [ "${value#0}" != "$value" ]; do value=${value#0}; done
    [ -n "$value" ] || value=0
    if [ "${#value}" -gt 4 ]; then
        value=1000
    else
        value=$((value))
        [ "$value" -le 1000 ] || value=1000
    fi
    if [ "$value" -lt 1 ]; then
        printf 'GitHub search limit must be positive\n' >&2
        return 1
    fi
    printf '%s\n' "$value"
}

_hubfred_search_validate_paths() {
    if [ -z "${workflow_dir:-}" ] || [ -z "${cache_dir:-}" ] || [ -z "${session:-}" ] || [ "${session#/}" = "$session" ] || [ ! -d "$session" ]; then
        printf 'GitHub search requires workflow, cache, and absolute session paths\n' >&2
        return 1
    fi
    if [ -z "${token:-}" ]; then
        printf 'GitHub search requires an active token\n' >&2
        return 1
    fi
}

_hubfred_search_gh() {
    if [ -n "${gh_path:-}" ]; then
        GH_TOKEN="$token" GITHUB_TOKEN= GH_HOST=github.com GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 "$gh_path" "$@"
    else
        GH_TOKEN="$token" GITHUB_TOKEN= GH_HOST=github.com GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 gh "$@"
    fi
}
_hubfred_search_exec_gh() {
    if [ -n "${gh_path:-}" ]; then
        GH_TOKEN="$token" GITHUB_TOKEN= GH_HOST=github.com GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 exec "$gh_path" "$@"
    else
        GH_TOKEN="$token" GITHUB_TOKEN= GH_HOST=github.com GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 exec gh "$@"
    fi
}

_hubfred_search_tracked_child() {
    local status
    _hubfred_search_child_pending=1
    "$@" &
    _hubfred_search_active_child=$!
    _hubfred_search_child_pending=0
    if [ "${_hubfred_search_cancel_requested:-0}" -ne 0 ]; then
        kill -TERM "$_hubfred_search_active_child" 2>/dev/null || :
        wait "$_hubfred_search_active_child" 2>/dev/null || :
        _hubfred_search_active_child=
        exit 143
    fi
    if wait "$_hubfred_search_active_child"; then
        status=0
    else
        status=$?
    fi
    _hubfred_search_active_child=
    return "$status"
}

_hubfred_search_worker_exit() {
    local status="$1"
    trap - EXIT
    if [ -n "${_hubfred_search_active_child:-}" ]; then
        kill -TERM "$_hubfred_search_active_child" 2>/dev/null || :
        wait "$_hubfred_search_active_child" 2>/dev/null || :
        _hubfred_search_active_child=
    fi
    printf '%s\n' "$status" > "$_hubfred_search_worker_status_path" || :
}

_hubfred_search_worker_signal() {
    [ "${_hubfred_search_signal_handling:-0}" -eq 0 ] || return 0
    _hubfred_search_signal_handling=1
    _hubfred_search_cancel_requested=1
    if [ -n "${_hubfred_search_active_child:-}" ]; then
        kill -TERM "$_hubfred_search_active_child" 2>/dev/null || :
        wait "$_hubfred_search_active_child" 2>/dev/null || :
        _hubfred_search_active_child=
    fi
    if [ "${_hubfred_search_child_pending:-0}" -eq 0 ]; then
        trap - INT TERM
        exit 143
    fi
    _hubfred_search_signal_handling=0
}

_hubfred_search_worker() {
    local phase="$1" status_path="$2"
    shift 2
    _hubfred_search_worker_status_path="$status_path"
    _hubfred_search_active_child=
    _hubfred_search_child_pending=0
    _hubfred_search_cancel_requested=0
    _hubfred_search_signal_handling=0
    trap '_hubfred_search_worker_exit "$?"' EXIT
    trap '_hubfred_search_worker_signal' INT TERM
    case "$phase" in
        first) _hubfred_search_first_category "$@" ;;
        more) _hubfred_search_more_category "$@" ;;
        *) return 1 ;;
    esac
}

_hubfred_search_cancel_workers() {
    local index pid
    for index in "${!pids[@]}"; do
        pid="${pids[$index]}"
        [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null || :
    done
    for index in "${!pids[@]}"; do
        pid="${pids[$index]}"
        if [ -n "$pid" ]; then
            wait "$pid" 2>/dev/null || :
            pids[$index]=
        fi
    done
    for index in "${!worker_status_files[@]}"; do
        rm -f "${worker_status_files[$index]}" 2>/dev/null || :
    done
}

_hubfred_search_parallel_signal() {
    _hubfred_search_parallel_interrupted=1
    trap '' INT TERM
    _hubfred_search_cancel_workers
}

_hubfred_search_restore_signal_traps() {
    local old_int_trap="$1" old_term_trap="$2"
    if [ -n "$old_int_trap" ]; then eval "$old_int_trap"; else trap - INT; fi
    if [ -n "$old_term_trap" ]; then eval "$old_term_trap"; else trap - TERM; fi
}

_hubfred_search_wait_workers() {
    local index pid worker_status active
    while :; do
        if [ "$_hubfred_search_parallel_interrupted" -ne 0 ]; then
            _hubfred_search_cancel_workers
            return 1
        fi
        active=0
        for index in "${!pids[@]}"; do
            pid="${pids[$index]}"
            [ -n "$pid" ] || continue
            if [ -s "${worker_status_files[$index]}" ]; then
                IFS= read -r worker_status < "${worker_status_files[$index]}" || worker_status=
                if [ "$worker_status" != 0 ]; then
                    _hubfred_search_cancel_workers
                    return 1
                fi
                if wait "$pid"; then
                    pids[$index]=
                    if ! rm -f "${worker_status_files[$index]}"; then
                        _hubfred_search_cancel_workers
                        return 1
                    fi
                else
                    pids[$index]=
                    _hubfred_search_cancel_workers
                    return 1
                fi
            elif ! kill -0 "$pid" 2>/dev/null && [ ! -s "${worker_status_files[$index]}" ]; then
                wait "$pid" 2>/dev/null || :
                pids[$index]=
                _hubfred_search_cancel_workers
                return 1
            else
                active=1
            fi
        done
        [ "$active" -eq 1 ] || break
        if ! /bin/sleep 0.01; then
            _hubfred_search_cancel_workers
            return 1
        fi
    done
    [ "$_hubfred_search_parallel_interrupted" -eq 0 ]
}



_hubfred_search_lock() {
    local attempts=0
    while ! mkdir "$session/.search-pacer-lock" 2>/dev/null; do
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 200 ]; then return 1; fi
        _hubfred_search_tracked_child /bin/sleep 0.01 || return 1
    done
}

_hubfred_search_pacer_wait() {
    local next now delay
    while :; do
        _hubfred_search_lock || return 1
        next=0
        if [ -r "$session/.search-pacer-next" ]; then
            IFS= read -r next < "$session/.search-pacer-next" || next=0
        fi
        rmdir "$session/.search-pacer-lock" || return 1
        case "$next" in ''|*[!0-9]*) next=0 ;; esac
        now=$(/bin/date +%s) || return 1
        if [ "$next" -le "$now" ]; then return 0; fi
        delay=$((next - now))
        if ! _hubfred_search_tracked_child /bin/sleep "$delay"; then return 1; fi
    done
}

_hubfred_search_pacer_defer() {
    local target="$1" current temporary
    [ "$target" -gt 0 ] || return 0
    _hubfred_search_lock || return 1
    current=0
    if [ -r "$session/.search-pacer-next" ]; then
        IFS= read -r current < "$session/.search-pacer-next" || current=0
    fi
    case "$current" in ''|*[!0-9]*) current=0 ;; esac
    if [ "$target" -gt "$current" ]; then
        temporary=$(mktemp "$session/.search-pacer.XXXXXX") || {
            rmdir "$session/.search-pacer-lock" 2>/dev/null || :
            return 1
        }
        if ! printf '%s\n' "$target" > "$temporary" || ! mv -f "$temporary" "$session/.search-pacer-next"; then
            rm -f "$temporary"
            rmdir "$session/.search-pacer-lock" 2>/dev/null || :
            return 1
        fi
    fi
    rmdir "$session/.search-pacer-lock"
}

_hubfred_search_retry_at() {
    local retry_after="$1" remaining="$2" reset="$3" now="$4" seconds target
    case "$retry_after" in
        ''|*[!0-9]*) ;;
        *)
            while [ "${retry_after#0}" != "$retry_after" ]; do retry_after=${retry_after#0}; done
            [ -n "$retry_after" ] || retry_after=0
            if [ "${#retry_after}" -lt 3 ] || { [ "${#retry_after}" -eq 3 ] && [ "$retry_after" -lt 120 ]; }; then
                seconds=$((retry_after))
                if [ "$seconds" -lt 120 ]; then
                    printf '%s\n' "$((now + seconds + 1))"
                    return 0
                fi
            fi
            ;;
    esac
    if [ "$remaining" = 0 ]; then
        case "$reset" in
            ''|*[!0-9]*) ;;
            *)
                while [ "${reset#0}" != "$reset" ]; do reset=${reset#0}; done
                [ -n "$reset" ] || reset=0
                if [ "${#reset}" -le 12 ]; then
                    target=$((reset + 1))
                    if [ "$((target - now))" -le 120 ]; then
                        [ "$target" -gt "$now" ] || target=$((now + 1))
                        printf '%s\n' "$target"
                        return 0
                    fi
                fi
                ;;
        esac
    fi
    printf '0\n'
}

_hubfred_search_request_page() {
    local query="$1" per_page="$2" page="$3" output="$4"
    local attempt=0 raw body metadata command_status http_code retry_after remaining reset now retry_at
    while [ "$attempt" -lt 3 ]; do
        if ! _hubfred_search_pacer_wait; then
            printf 'Could not wait for the GitHub search rate limit\n' >&2
            return 1
        fi
        raw=$(mktemp "$session/.search-response.XXXXXX") || return 1
        body=$(mktemp "$session/.search-body.XXXXXX") || { rm -f "$raw"; return 1; }
        if _hubfred_search_tracked_child _hubfred_search_exec_gh api --include --method GET search/issues \
            -f "q=$query" -f sort=updated -f order=desc \
            -F "per_page=$per_page" -F "page=$page" > "$raw" 2>/dev/null; then
            command_status=0
        else
            command_status=$?
        fi
        metadata=$(/usr/bin/perl -e '
            my ($source, $destination) = @ARGV;
            open my $in, "<", $source or exit 1;
            binmode $in;
            local $/;
            my $wire = <$in>;
            $wire =~ /\A(HTTP\/\S+\s+(\d{3})[^\r\n]*)\r?\n(.*)\z/s or exit 1;
            my ($code, $rest) = ($2, $3);
            my ($headers, $content);
            if ($rest =~ /\A\r?\n(.*)\z/s) {
                ($headers, $content) = ("", $1);
            } elsif ($rest =~ /\A(.*?)\r?\n\r?\n(.*)\z/s) {
                ($headers, $content) = ($1, $2);
            } else {
                exit 1;
            }
            open my $out, ">", $destination or exit 1;
            binmode $out;
            print {$out} $content or exit 1;
            close $out or exit 1;
            my %header;
            for my $line (split /\r?\n/, $headers) {
                if ($line =~ /^([^:]+):\s*(.*?)\s*$/) { $header{lc $1} = $2; }
            }
            print join("|", $code, $header{"retry-after"} // "-", $header{"x-ratelimit-remaining"} // "-", $header{"x-ratelimit-reset"} // "-");
        ' "$raw" "$body") || {
            rm -f "$raw" "$body"
            printf 'GitHub search response did not contain HTTP headers\n' >&2
            return 1
        }
        rm -f "$raw"
        IFS='|' read -r http_code retry_after remaining reset <<< "$metadata"
        now=$(/bin/date +%s) || { rm -f "$body"; return 1; }
        retry_at=$(_hubfred_search_retry_at "$retry_after" "$remaining" "$reset" "$now") || { rm -f "$body"; return 1; }
        if [ "$command_status" -ne 0 ] && [ "$http_code" != 403 ] && [ "$http_code" != 429 ]; then retry_at=0; fi
        if ! _hubfred_search_pacer_defer "$retry_at"; then
            rm -f "$body"
            printf 'Could not save the GitHub search rate limit\n' >&2
            return 1
        fi
        if [ "$command_status" -ne 0 ] && { [ "$http_code" = 403 ] || [ "$http_code" = 429 ]; } && [ "$retry_at" -gt 0 ] && [ "$attempt" -lt 2 ]; then
            rm -f "$body"
            attempt=$((attempt + 1))
            continue
        fi
        if [ "$command_status" -ne 0 ] || [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
            rm -f "$body"
            printf 'GitHub search request failed for page %s\n' "$page" >&2
            return 1
        fi
        if ! jq -e '
            (.items | type == "array") and
            (.total_count | type == "number" and . >= 0 and floor == .) and
            ((.incomplete_results // false) == false)
        ' "$body" >/dev/null 2>&1; then
            rm -f "$body"
            printf 'GitHub returned an invalid or incomplete search page\n' >&2
            return 1
        fi
        if ! jq -c . "$body" > "$output"; then
            rm -f "$body"
            return 1
        fi
        rm -f "$body"
        return 0
    done
    printf 'GitHub search rate limit retries were exhausted\n' >&2
    return 1
}

_hubfred_search_write_first_receipt() {
    local index="$1" category="$2" query="$3" per_page="$4" limit="$5"
    local response="$6" path="$session/category-$index.json" temporary
    if [ -e "$path" ]; then
        if jq -e --arg kind "$kind" --arg category "$category" --arg query "$query" --argjson perPage "$per_page" '
            .kind == $kind and .category == $category and .query == $query and
            .perPage == $perPage and (.items | type == "array") and
            .loaded == (.items | length) and
            (.totalCount | type == "number" and . >= 0 and floor == .) and
            (.nextPage | type == "number" and . >= 0 and . <= 10 and floor == .)
        ' "$path" >/dev/null 2>&1; then
            return 0
        fi
        printf 'Pending GitHub search category does not match the current query\n' >&2
        return 1
    fi
    temporary=$(mktemp "$session/.category-$index.XXXXXX") || return 1
    jq -c --arg kind "$kind" --arg category "$category" --arg query "$query" \
        --argjson perPage "$per_page" --argjson limit "$limit" '
        . as $response
        | ($response.items[:$limit]) as $items
        | {
            kind: $kind,
            category: $category,
            query: $query,
            perPage: $perPage,
            loaded: ($items | length),
            totalCount: $response.total_count,
            nextPage: (if ($items | length) > 0 and ($items | length) < $limit and ($items | length) < $response.total_count then 2 else 0 end),
            items: $items
        }
    ' "$response" > "$temporary" || { rm -f "$temporary"; return 1; }
    chmod 600 "$temporary" || { rm -f "$temporary"; return 1; }
    mv -f "$temporary" "$path"
}

_hubfred_search_first_category() {
    local index="$1" category="$2" query="$3" per_page="$4" limit="$5"
    local path="$session/category-$index.json" response temporary
    if [ -e "$path" ]; then
        _hubfred_search_write_first_receipt "$index" "$category" "$query" "$per_page" "$limit" "$path"
        return $?
    fi
    response=$(mktemp "$session/.search-page.XXXXXX") || return 1
    if ! _hubfred_search_request_page "$query" "$per_page" 1 "$response"; then
        rm -f "$response"
        return 1
    fi
    _hubfred_search_write_first_receipt "$index" "$category" "$query" "$per_page" "$limit" "$response"
    local result=$?
    rm -f "$response"
    return "$result"
}

_hubfred_search_category_kind() {
    local kind="$1" index="$2"
    if [ "$kind" = all ] && [ "$index" -ge 2 ]; then
        printf 'issues\n'
    else
        [ "$kind" = all ] && printf 'prs\n' || printf '%s\n' "$kind"
    fi
}

_hubfred_search_more_category() {
    local index="$1" category="$2" limit="$3"
    local path="$session/category-$index.json" query per_page loaded next_page page response temporary
    if ! jq -e --arg kind "$kind" --arg category "$category" '
        .kind == $kind and .category == $category and (.query | type == "string" and length > 0) and
        (.items | type == "array") and .loaded == (.items | length) and
        (.loaded | type == "number" and . >= 0 and floor == .) and
        (.totalCount | type == "number" and . >= 0 and floor == .) and
        (.perPage | type == "number" and . >= 1 and . <= 100 and floor == .) and
        (.nextPage | type == "number" and . >= 0 and . <= 10 and floor == .)
    ' "$path" >/dev/null 2>&1; then
        printf 'Pending GitHub search category is missing or invalid\n' >&2
        return 1
    fi
    query=$(jq -r '.query' "$path") || return 1
    per_page=$(jq -r '.perPage' "$path") || return 1
    loaded=$(jq -r '.loaded' "$path") || return 1
    next_page=$(jq -r '.nextPage' "$path") || return 1
    while [ "$next_page" -gt 0 ] && [ "$next_page" -le 10 ] && [ "$loaded" -lt "$limit" ]; do
        page=$next_page
        response=$(mktemp "$session/.search-page.XXXXXX") || return 1
        if ! _hubfred_search_request_page "$query" "$per_page" "$page" "$response"; then
            rm -f "$response"
            return 1
        fi
        temporary=$(mktemp "$session/.category-$index.XXXXXX") || { rm -f "$response"; return 1; }
        if ! jq -c --argjson limit "$limit" --argjson page "$page" --slurpfile response "$response" '
            . as $receipt
            | ($response[0].items[:($limit - $receipt.loaded)]) as $append
            | .items += $append
            | .loaded += ($append | length)
            | .totalCount = $response[0].total_count
            | .nextPage = (if ($append | length) > 0 and .loaded < $limit and .loaded < .totalCount then $page + 1 else 0 end)
        ' "$path" > "$temporary"; then
            rm -f "$response" "$temporary"
            return 1
        fi
        chmod 600 "$temporary" || { rm -f "$response" "$temporary"; return 1; }
        if ! mv -f "$temporary" "$path"; then rm -f "$response" "$temporary"; return 1; fi
        rm -f "$response"
        loaded=$(jq -r '.loaded' "$path") || return 1
        next_page=$(jq -r '.nextPage' "$path") || return 1
    done
}

_hubfred_search_prepare_icons() {
    local kind="$1" icon_dir="$cache_dir/octicons-v5" index color state source temporary
    local -a colors states
    colors=(AC6B49 4269A5 A48332 B15F91 4E94B8 62636D)
    case "$kind" in
        prs) states=(ready draft) ;;
        issues) states=(issue) ;;
        all) states=(ready draft issue) ;;
        *) return 1 ;;
    esac
    mkdir -p "$icon_dir" || return 1
    for index in 0 1 2 3 4 5; do
        color=${colors[$index]}
        for state in "${states[@]}"; do
            [ -s "$icon_dir/$index-$state.png" ] && continue
            case "$state" in
                ready) source="$workflow_dir/octicons/git-pull-request-16.svg" ;;
                draft) source="$workflow_dir/octicons/git-pull-request-draft-16.svg" ;;
                issue) source="$workflow_dir/octicons/issue-opened-16.svg" ;;
            esac
            temporary=$(mktemp -d "$icon_dir/.hubfred-icon.XXXXXX") || return 1
            if ! ICON_COLOR="$color" /usr/bin/perl -pe '
                s/width="16" height="16"/width="64" height="64"/;
                s/viewBox="0 0 16 16"/viewBox="-1.142857 -1.142857 18.285714 18.285714"/;
                s/<svg /<svg fill="#$ENV{ICON_COLOR}" /
            ' "$source" > "$temporary/icon.svg"; then
                rm -rf "$temporary"
                return 1
            fi
            if ! /usr/bin/sips -s format png "$temporary/icon.svg" --out "$temporary/icon.png" >/dev/null 2>&1 || [ ! -s "$temporary/icon.png" ]; then
                rm -rf "$temporary"
                printf 'Could not create a GitHub search icon\n' >&2
                return 1
            fi
            if [ ! -s "$icon_dir/$index-$state.png" ]; then
                if ! mv -f "$temporary/icon.png" "$icon_dir/$index-$state.png"; then
                    rm -rf "$temporary"
                    return 1
                fi
            fi
            rm -rf "$temporary"
        done
    done
}


_hubfred_search_format() {
    local include_more="$1" more=false index receipt_file output icon_dir result
    local -a receipt_files
    receipt_files=()
    for index in "${!hubfred_search_qualifiers[@]}"; do
        receipt_file="$session/category-$index.json"
        if [ ! -f "$receipt_file" ]; then
            printf 'Pending GitHub search category is missing\n' >&2
            return 1
        fi
        receipt_files+=("$receipt_file")
    done
    _hubfred_search_prepare_icons "$kind" || return 1
    icon_dir="$cache_dir/octicons-v5"
    output=$(mktemp "$session/.search-results.XXXXXX") || return 1
    if ! jq -s -c -f "$workflow_dir/search-results.jq" --arg kind "$kind" --arg iconDir "$icon_dir" "${receipt_files[@]}" > "$output"; then
        rm -f "$output"
        printf 'Could not format GitHub search results\n' >&2
        return 1
    fi
    if [ "$include_more" = true ]; then
        for receipt_file in "${receipt_files[@]}"; do
            if [ "$(jq -r '.nextPage' "$receipt_file")" -gt 0 ]; then
                more=true
                break
            fi
        done
        jq -c --argjson more "$more" '{items: .items, more: $more}' "$output"
    else
        cat "$output"
    fi
    result=$?
    rm -f "$output"
    return "$result"
}

search_first() {
    local requested_limit cutoff_value login per_page index category_kind category_key query worker_status
    local old_int_trap old_term_trap parallel_status
    local -a hubfred_search_qualifiers pids worker_status_files categories queries
    _hubfred_search_categories "${kind:-}" || return 1
    _hubfred_search_validate_paths || return 1
    requested_limit=$(_hubfred_search_limit "${1:-}") || return 1
    cutoff_value="${2:-}"
    per_page=$requested_limit
    [ "$per_page" -le 100 ] || per_page=100
    if login=$(_hubfred_search_gh api user --jq .login 2>/dev/null); then
        login=${login//$'\r'/}
    else
        printf 'Could not look up the GitHub login\n' >&2
        return 1
    fi
    if [ -z "$login" ]; then
        printf 'GitHub returned an empty login\n' >&2
        return 1
    fi
    categories=()
    queries=()
    for index in "${!hubfred_search_qualifiers[@]}"; do
        category_kind=$(_hubfred_search_category_kind "$kind" "$index") || return 1
        category_key="$category_kind:${hubfred_search_qualifiers[$index]}"
        query="is:$( [ "$category_kind" = prs ] && printf pr || printf issue ) is:open ${hubfred_search_qualifiers[$index]}:$login"
        [ -z "$cutoff_value" ] || query="$query updated:>=$cutoff_value"
        categories+=("$category_key")
        queries+=("$query")
    done
    pids=()
    worker_status_files=()
    for index in "${!hubfred_search_qualifiers[@]}"; do
        worker_status=$(mktemp "$session/.search-worker.XXXXXX") || {
            for worker_status in "${worker_status_files[@]}"; do rm -f "$worker_status"; done
            return 1
        }
        worker_status_files+=("$worker_status")
    done
    _hubfred_search_parallel_interrupted=0
    old_int_trap=$(trap -p INT)
    old_term_trap=$(trap -p TERM)
    trap '_hubfred_search_parallel_signal' INT TERM
    for index in "${!hubfred_search_qualifiers[@]}"; do
        [ "$_hubfred_search_parallel_interrupted" -eq 0 ] || break
        (_hubfred_search_worker first "${worker_status_files[$index]}" "$index" \
            "${categories[$index]}" "${queries[$index]}" "$per_page" "$requested_limit") &
        pids+=("$!")
        [ "$_hubfred_search_parallel_interrupted" -eq 0 ] || break
    done
    if _hubfred_search_wait_workers; then
        parallel_status=0
    else
        parallel_status=$?
    fi
    _hubfred_search_restore_signal_traps "$old_int_trap" "$old_term_trap"
    [ "$parallel_status" -eq 0 ] || return 1
    _hubfred_search_format true
}

search_more() {
    local requested_limit index category_kind category_key worker_status
    local old_int_trap old_term_trap parallel_status
    local -a hubfred_search_qualifiers pids worker_status_files categories
    _hubfred_search_categories "${kind:-}" || return 1
    _hubfred_search_validate_paths || return 1
    requested_limit=$(_hubfred_search_limit "${1:-}") || return 1
    categories=()
    for index in "${!hubfred_search_qualifiers[@]}"; do
        category_kind=$(_hubfred_search_category_kind "$kind" "$index") || return 1
        category_key="$category_kind:${hubfred_search_qualifiers[$index]}"
        categories+=("$category_key")
    done
    pids=()
    worker_status_files=()
    for index in "${!hubfred_search_qualifiers[@]}"; do
        worker_status=$(mktemp "$session/.search-worker.XXXXXX") || {
            for worker_status in "${worker_status_files[@]}"; do rm -f "$worker_status"; done
            return 1
        }
        worker_status_files+=("$worker_status")
    done
    _hubfred_search_parallel_interrupted=0
    old_int_trap=$(trap -p INT)
    old_term_trap=$(trap -p TERM)
    trap '_hubfred_search_parallel_signal' INT TERM
    for index in "${!hubfred_search_qualifiers[@]}"; do
        [ "$_hubfred_search_parallel_interrupted" -eq 0 ] || break
        (_hubfred_search_worker more "${worker_status_files[$index]}" "$index" \
            "${categories[$index]}" "$requested_limit") &
        pids+=("$!")
        [ "$_hubfred_search_parallel_interrupted" -eq 0 ] || break
    done
    if _hubfred_search_wait_workers; then
        parallel_status=0
    else
        parallel_status=$?
    fi
    _hubfred_search_restore_signal_traps "$old_int_trap" "$old_term_trap"
    [ "$parallel_status" -eq 0 ] || return 1
    _hubfred_search_format false
}

