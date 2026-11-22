# One SQLite snapshot per view and kind; all views use the same credential and age checks.
cache_table="${cache_mode:-dashboard}"
case "$cache_table:${cache_kind:-${dashboard_kind:-prs}}" in
    dashboard:prs) cache_name=dashboard-v3.sqlite3 ;;
    dashboard:issues) cache_name=issues-dashboard-v3.sqlite3 ;;
    dashboard:all) cache_name=github-dashboard-v1.sqlite3 ;;
    picker:prs) cache_name=pr-picker-v1.sqlite3 ;;
    picker:issues) cache_name=issue-picker-v1.sqlite3 ;;
    picker:all) cache_name=github-picker-v1.sqlite3 ;;
    *) return 2 ;;
esac
cache_dir="${alfred_workflow_cache:-$HOME/Library/Caches/jp.kasutera.hubfred}"
cache="$cache_dir/$cache_name"

cache_sqlite() {
    /usr/bin/sqlite3 -batch -bail -init /dev/null "$@"
}

# Resolve the github.com credential the search will use, without changing the
# caller's environment. The dashboard key must follow the same credential.
resolve_dashboard_auth() {
    dashboard_auth_token=
    if [[ -n "${GH_TOKEN:-}" ]]; then
        dashboard_auth_token=$GH_TOKEN
    elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
        dashboard_auth_token=$GITHUB_TOKEN
    else
        dashboard_auth_token=$(
            PATH="/opt/homebrew/bin:/usr/local/bin:${PATH:-}" \
                GH_HOST=github.com GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \
                gh auth token --hostname github.com 2>/dev/null
        ) || dashboard_auth_token=
    fi

    identity=
    if [[ -z "$dashboard_auth_token" ]]; then
        dashboard_auth_resolved=false
        return 0
    fi
    identity=$(printf 'token\0%s' "$dashboard_auth_token" | /usr/bin/shasum -a 256) || {
        dashboard_auth_token=
        dashboard_auth_resolved=false
        identity=
        return 0
    }
    dashboard_auth_resolved=true
}

resolve_dashboard_auth

source "${BASH_SOURCE[0]%/*}/cache-decisions.sh"

cache_read() {
    age=$CACHE_STALE_SECONDS
    cached=
    cached_identity=
    cached_digest=
    local columns='unixepoch() - saved_at, digest' state
    if [[ "$1" == list ]]; then columns+=', list'; fi
    if [[ -s "$cache" ]] && state=$(cache_sqlite -readonly -separator $'\n' "$cache" \
        "SELECT $columns FROM $cache_table WHERE identity = '$identity';" 2>/dev/null) &&
        [[ -n "$state" ]]; then
        {
            IFS= read -r age
            IFS= read -r cached_digest
            IFS= read -r cached || :
        } <<< "$state"
        cached_identity=$identity
    fi
}

# Status 2 means the search was invalidated by an identity change, even on failure.
cache_refresh_search() {
    local search_identity=$identity failed=0
    results=$(GH_TOKEN="$dashboard_auth_token" /bin/bash "$@") || failed=1
    resolve_dashboard_auth
    [[ "$dashboard_auth_resolved" == true && "$identity" == "$search_identity" ]] || return 2
    return "$failed"
}

cache_digest() {
    printf '%s' "$results" | /usr/bin/shasum -a 256
}

cache_write() (
    umask 077
    /bin/mkdir -p "$cache_dir"
    temporary=$(/usr/bin/mktemp "$cache_dir/$cache_table.XXXXXX")
    trap '/bin/rm -f "$temporary" "$temporary-journal"' EXIT
    # Publish the list and any descriptions together in one atomic snapshot.
    /usr/bin/jq -r --arg table "$cache_table" --arg key "$identity" --arg digest "$1" '
        def literal: "\u0027" + gsub("\u0027"; "\u0027\u0027") + "\u0027";
        ([
            "BEGIN;",
            "CREATE TABLE \($table) (identity TEXT NOT NULL, saved_at INTEGER NOT NULL, digest TEXT NOT NULL, list TEXT NOT NULL);",
            "CREATE TABLE bodies (url TEXT PRIMARY KEY, body TEXT NOT NULL) WITHOUT ROWID;",
            "INSERT INTO \($table) VALUES (\($key | literal), unixepoch(), \($digest | literal), \({items: [.items[] | del(.body)]} | @json | literal));"
        ][]),
        (.items[] | select(.uid and has("body")) |
            "INSERT INTO bodies VALUES (\(.uid | literal), \((.body // "") | @json | literal));"),
        "COMMIT;"
    ' <<< "$results" | cache_sqlite "$temporary"
    /bin/mv -f "$temporary" "$cache"
)
