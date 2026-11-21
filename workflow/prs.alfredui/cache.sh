# Shared by the dashboard loader and preview.
case "${dashboard_kind:-prs}" in
    prs) cache_name=dashboard-v2.json ;;
    issues) cache_name=issues-dashboard-v2.json ;;
    *) exit 2 ;;
esac
cache_dir="${alfred_workflow_cache:-$HOME/Library/Caches/jp.kasutera.hubfred}"
cache="$cache_dir/$cache_name"

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
