# Shared by the dashboard loader and preview.
case "${dashboard_kind:-prs}" in
    prs) cache_name=dashboard-v2.json ;;
    issues) cache_name=issues-dashboard-v2.json ;;
    *) exit 2 ;;
esac
cache_dir="${alfred_workflow_cache:-$HOME/Library/Caches/jp.kasutera.hubfred}"
cache="$cache_dir/$cache_name"

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
