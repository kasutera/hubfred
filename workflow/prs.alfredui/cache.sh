#!/bin/bash

# Shared cache API return codes:
# cache_init: 0 initialized, 2 unsupported kind, 3 invalid cache settings/path.
# cache_credential: 0 resolved, 1 no credential, 2 digest failure.
# cache_read: 0 (including a miss or unreadable cache), 2 unsupported mode.
# cache_write: 0 saved, 2 unsupported mode, 3 missing identity, 4 invalid input,
#              5 directory, temporary-file, SQLite, or atomic-publish failure.
# cache_body: 0 whether found or not, 2 missing arguments.
# Sourcing this file only defines functions; callers set umask 077 before writes.

cache_normalize_setting() {
    local value=$1 fallback=$2 minimum=$3 maximum=$4 normalized
    if [[ -z "$value" ]]; then
        printf '%s\n' "$fallback"
        return 0
    fi
    case "$value" in
        *[!0-9]*) printf '%s\n' "$fallback"; return 0 ;;
    esac
    normalized=$value
    while [[ "$normalized" == 0* && "$normalized" != 0 ]]; do
        normalized=${normalized#0}
    done
    [[ -n "$normalized" ]] || normalized=0
    if (( ${#normalized} > ${#maximum} )); then
        printf '%s\n' "$maximum"
    elif (( ${#normalized} == ${#maximum} )) && [[ "$normalized" > "$maximum" ]]; then
        printf '%s\n' "$maximum"
    elif (( normalized < minimum )); then
        printf '%s\n' "$minimum"
    else
        printf '%s\n' "$normalized"
    fi
}

cache_init() {
    local requested_kind=${1:-} found_gh
    case "$requested_kind" in
        prs)
            cache_dashboard_name=dashboard-v3.sqlite3
            cache_scope_name=dashboard-scope-v1.sqlite3
            cache_picker_name=pr-picker-v2.sqlite3
            ;;
        issues)
            cache_dashboard_name=issues-dashboard-v3.sqlite3
            cache_scope_name=issues-dashboard-scope-v1.sqlite3
            cache_picker_name=issue-picker-v2.sqlite3
            ;;
        all)
            cache_dashboard_name=github-dashboard-v1.sqlite3
            cache_scope_name=github-dashboard-scope-v1.sqlite3
            cache_picker_name=github-picker-v2.sqlite3
            ;;
        *) return 2 ;;
    esac

    kind=$requested_kind
    limit=$(cache_normalize_setting "${hubfred_dashboard_limit:-}" 100 1 1000)
    days=$(cache_normalize_setting "${hubfred_dashboard_days:-}" 0 0 36500)
    cache_dir=${alfred_workflow_cache:-}
    if [[ -z "$cache_dir" ]]; then
        [[ -n "${HOME:-}" ]] || return 3
        cache_dir="$HOME/Library/Caches/jp.kasutera.hubfred"
    fi
    if [[ -e "$cache_dir" && ! -d "$cache_dir" ]]; then
        return 3
    fi

    broad_path="$cache_dir/$cache_dashboard_name"
    picker_path="$cache_dir/$cache_picker_name"
    cache_scope=
    if (( limit == 1000 && days == 0 )); then
        cache_path=$broad_path
    else
        cache_path="$cache_dir/$cache_scope_name"
        cache_scope="$limit:$days"
    fi

    cutoff=
    if (( days > 0 )); then
        cutoff=$(/bin/date -u -v-"${days}"d '+%Y-%m-%dT%H:%M:%SZ') || return 3
        [[ -n "$cutoff" ]] || return 3
    fi

    CACHE_FRESH_SECONDS=60
    CACHE_STALE_SECONDS=3600
    gh_path=
    found_gh=$(command -v gh 2>/dev/null || true)
    if [[ -n "$found_gh" && -x "$found_gh" ]]; then
        case "$found_gh" in
            /*) gh_path=$found_gh ;;
            *) gh_path="$PWD/$found_gh" ;;
        esac
    else
        for found_gh in /opt/homebrew/bin/gh /usr/local/bin/gh; do
            if [[ -f "$found_gh" && -x "$found_gh" ]]; then
                gh_path=$found_gh
                break
            fi
        done
    fi
    return 0
}

cache_credential() {
    local carriage_return
    token=
    identity=
    if [[ -n "${GH_TOKEN:-}" ]]; then
        token=$GH_TOKEN
    elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
        token=$GITHUB_TOKEN
    elif [[ -n "${gh_path:-}" ]]; then
        token=$(GH_HOST=github.com GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \
            "$gh_path" auth token --hostname github.com 2>/dev/null) || token=
    fi
    carriage_return=$(/usr/bin/printf '\r')
    while [[ -n "$token" && "${token%$carriage_return}" != "$token" ]]; do
        token=${token%$carriage_return}
    done
    [[ -n "$token" ]] || return 1
    if ! identity=$(printf 'token\000%s' "$token" \
        | /usr/bin/shasum -a 256 \
        | /usr/bin/awk '{print $1 "  -"}'); then
        token=
        identity=
        return 2
    fi
    [[ -n "$identity" ]] || { token=; return 2; }
    return 0
}

cache_sql_literal() {
    local escaped
    escaped=$(printf '%s' "$1" | /usr/bin/perl -0777 -pe 's/\x27/\x27\x27/g') || return 1
    printf "'%s'" "$escaped"
}

cache_read() {
    local mode=${1:-} path table scope_clause identity_sql query raw seconds list stale_seconds
    age=$CACHE_STALE_SECONDS
    stale_seconds=$CACHE_STALE_SECONDS
    cached='{"items":[]}'
    case "$mode" in
        dashboard) path=${cache_path:-}; table=dashboard; scope_clause=${cache_scope:-} ;;
        picker) path=${picker_path:-}; table=picker; scope_clause= ;;
        broad) path=${broad_path:-}; table=dashboard; scope_clause= ;;
        *) return 2 ;;
    esac
    [[ -n "${identity:-}" && -f "$path" ]] || return 0
    identity_sql=$(cache_sql_literal "$identity") || return 0
    query="SELECT CASE WHEN unixepoch()-saved_at < -$stale_seconds THEN -$stale_seconds WHEN unixepoch()-saved_at > $stale_seconds THEN $stale_seconds ELSE unixepoch()-saved_at END || char(10) || list FROM $table WHERE identity = $identity_sql"
    if [[ -n "$scope_clause" ]]; then
        local scope_sql
        scope_sql=$(cache_sql_literal "$scope_clause") || return 0
        query="$query AND scope = $scope_sql"
    fi
    query="$query LIMIT 1;"
    raw=$(/usr/bin/sqlite3 -batch -bail -init /dev/null -readonly \
        -separator $'\n' "$path" "$query" 2>/dev/null) || raw=
    [[ "$raw" == *$'\n'* ]] || return 0
    seconds=${raw%%$'\n'*}
    list=${raw#*$'\n'}
    [[ "$seconds" =~ ^-?[0-9]+$ && -n "$list" ]] || return 0
    if (( seconds < 0 )); then return 0; fi
    cached=$(/usr/bin/jq -c '
        if type == "object"
            and (.items == null or (.items | type == "array"))
            and all(.items[]?;
                type == "object"
                and (.uid | type == "string" and length > 0)
                and (.arg | type == "string" and length > 0)
                and (.title | type == "string")
                and (.subtitle | type == "string")
                and (.match | type == "string")
                and (.icon | type == "object" and (.path | type == "string"))
                and (.updatedAt == null or (.updatedAt | type == "string"))
                and (.kind == null or (.kind | type == "string"))
                and (.reasons == null or (.reasons | type == "array" and all(.[]; type == "string")))
                and (.labels == null or (.labels | type == "array" and all(.[]; type == "string")))
            )
        then {items: [(.items // [])[] | del(.body)]}
        else error("expected an object containing valid item rows") end
    ' <<< "$list" 2>/dev/null) || {
        cached='{"items":[]}'
        return 0
    }
    age=$seconds
    return 0
}

cache_remove_temporary() {
    local path=${1:-}
    [[ -n "$path" ]] || return 0
    /bin/rm -f -- "$path" "$path-journal" "$path-wal" "$path-shm" \
        "$path.sql" "$path.bodies"
}

cache_write() {
    local mode=${1:-} json_file=${2:-} target table scope include_bodies
    local list_json list_sql identity_sql scope_sql columns values temporary body_file sql_file
    case "$mode" in
        dashboard)
            target=${cache_path:-}; table=dashboard; scope=${cache_scope:-}; include_bodies=true
            ;;
        picker)
            target=${picker_path:-}; table=picker; scope=; include_bodies=false
            ;;
        broad)
            target=${broad_path:-}; table=dashboard; scope=; include_bodies=true
            ;;
        *) return 2 ;;
    esac
    [[ -n "${identity:-}" ]] || return 3
    [[ -n "$target" && -r "$json_file" ]] || return 4
    list_json=$(/usr/bin/jq -c -e '
        if type == "object"
            and (.items == null or (.items | type == "array"))
            and all(.items[]?; type == "object" and (.body == null or ((.body | type) == "string" and (.uid | type) == "string" and (.uid | length) > 0)))
        then {items: [(.items // [])[] | del(.body)]}
        else error("expected an object containing a valid item array") end
    ' "$json_file" 2>/dev/null) || return 4
    list_sql=$(cache_sql_literal "$list_json") || return 4
    identity_sql=$(cache_sql_literal "$identity") || return 4
    if [[ -n "$scope" ]]; then
        scope_sql=$(cache_sql_literal "$scope") || return 4
        columns='identity, saved_at, digest, list, scope'
        values="$identity_sql, unixepoch(), '', $list_sql, $scope_sql"
    else
        columns='identity, saved_at, digest, list'
        values="$identity_sql, unixepoch(), '', $list_sql"
    fi

    /bin/mkdir -p -- "$cache_dir" || return 5
    temporary=$(/usr/bin/mktemp "$cache_dir/.dashboard.XXXXXXXX") || return 5
    body_file="$temporary.bodies"
    sql_file="$temporary.sql"
    if ! /bin/chmod 600 "$temporary"; then
        cache_remove_temporary "$temporary"
        return 5
    fi
    if [[ "$include_bodies" == true ]]; then
        if ! /usr/bin/jq -r '
            def sqlquote: "\u0027" + gsub("\u0027"; "\u0027\u0027") + "\u0027";
            (.items // [])[]
            | select(.body != null)
            | "INSERT INTO bodies VALUES (\((.uid | sqlquote)), \((.body | tojson | sqlquote)));"
        ' "$json_file" > "$body_file" 2>/dev/null; then
            cache_remove_temporary "$temporary"
            return 4
        fi
    else
        : > "$body_file" || { cache_remove_temporary "$temporary"; return 5; }
    fi
    if ! /bin/chmod 600 "$body_file"; then
        cache_remove_temporary "$temporary"
        return 5
    fi

    {
        printf 'BEGIN IMMEDIATE;\n'
        if [[ -n "$scope" ]]; then
            printf 'CREATE TABLE %s (identity TEXT NOT NULL, saved_at INTEGER NOT NULL, digest TEXT NOT NULL, list TEXT NOT NULL, scope TEXT NOT NULL);\n' "$table"
        else
            printf 'CREATE TABLE %s (identity TEXT NOT NULL, saved_at INTEGER NOT NULL, digest TEXT NOT NULL, list TEXT NOT NULL);\n' "$table"
        fi
        printf 'CREATE TABLE bodies (url TEXT PRIMARY KEY, body TEXT NOT NULL) WITHOUT ROWID;\n'
        printf 'INSERT INTO %s (%s) VALUES (%s);\n' "$table" "$columns" "$values"
    } > "$sql_file" || {
        cache_remove_temporary "$temporary"
        return 5
    }
    if [[ "$include_bodies" == true ]] && ! /bin/cat "$body_file" >> "$sql_file"; then
        cache_remove_temporary "$temporary"
        return 5
    fi
    printf 'COMMIT;\n' >> "$sql_file" || {
        cache_remove_temporary "$temporary"
        return 5
    }
    if ! /bin/chmod 600 "$sql_file" || \
        ! /usr/bin/sqlite3 -batch -bail -init /dev/null "$temporary" < "$sql_file" >/dev/null 2>&1 || \
        ! /bin/chmod 600 "$temporary"; then
        cache_remove_temporary "$temporary"
        return 5
    fi
    /bin/rm -f -- "$temporary.sql" "$temporary.bodies" "$temporary-journal" "$temporary-wal" "$temporary-shm"
    if ! /bin/mv -f -- "$temporary" "$target"; then
        cache_remove_temporary "$temporary"
        return 5
    fi
    return 0
}

cache_body() {
    local uid=${1:-} uid_sql identity_sql scope_sql query body
    [[ -n "$uid" && -n "${identity:-}" ]] || return 0
    [[ -n "${cache_path:-}" && -f "$cache_path" ]] || return 0
    uid_sql=$(cache_sql_literal "$uid") || return 0
    identity_sql=$(cache_sql_literal "$identity") || return 0
    query="SELECT body FROM bodies WHERE url = $uid_sql AND EXISTS (SELECT 1 FROM dashboard WHERE identity = $identity_sql"
    if [[ -n "${cache_scope:-}" ]]; then
        scope_sql=$(cache_sql_literal "$cache_scope") || return 0
        query="$query AND scope = $scope_sql"
    fi
    query="$query) LIMIT 1;"
    body=$(/usr/bin/sqlite3 -batch -bail -init /dev/null -readonly \
        "$cache_path" "$query" 2>/dev/null) || body=
    [[ -n "$body" ]] && printf '%s\n' "$body"
    return 0
}
