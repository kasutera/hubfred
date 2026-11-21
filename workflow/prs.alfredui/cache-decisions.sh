# Pure age and identity checks shared by the dashboard loader and its tests.
cache_should_skip_fetch() {
    [[ "$2" == "$3" ]] && (( $1 < 30 ))
}

cache_should_show_cached() {
    [[ "$2" == "$3" ]] && (( $1 < 600 ))
}

cache_should_reuse_after_failure() {
    [[ "$4" == true ]] && cache_should_show_cached "$1" "$2" "$3"
}
