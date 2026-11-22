# Pure age and identity checks shared by pickers and dashboards.
readonly CACHE_FRESH_SECONDS=60
readonly CACHE_STALE_SECONDS=3600

cache_should_skip_fetch() {
    [[ "$2" == "$3" ]] && (( $1 < CACHE_FRESH_SECONDS ))
}

cache_should_show_cached() {
    [[ "$2" == "$3" ]] && (( $1 < CACHE_STALE_SECONDS ))
}

cache_should_reuse_after_failure() {
    [[ "$4" == true ]] && cache_should_show_cached "$1" "$2" "$3"
}
