#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."

bundle=org.hubfred.screenshots
production_bundle=jp.kasutera.hubfred
legacy_production_bundle=jp.kasutera.github-prs
archive="$PWD/dist/hubfred-screenshots.alfredworkflow"
work=$(/usr/bin/mktemp -d)
production_paths=()
production_bundles=()
production_backups=()
production_count=0
installed=
preferences=
theme_backup=
restore_demo=false
restore_production=false
restore_theme=false

reload() {
    /usr/bin/osascript -e "tell application id \"com.runningwithcrayons.Alfred\" to reload workflow \"$1\""
}

backup_theme_preferences() {
    local plist relative
    /bin/mkdir -p "$theme_backup" || return 1
    for plist in "$preferences"/local/*/appearance/prefs.plist; do
        [[ -f "$plist" ]] || continue
        relative=${plist#"$preferences"/}
        /bin/mkdir -p "$theme_backup/${relative%/*}" || return 1
        /bin/cp -p "$plist" "$theme_backup/$relative" || return 1
    done
}

restore_theme_preferences() {
    local backup current relative failed=false
    for backup in "$theme_backup"/local/*/appearance/prefs.plist; do
        [[ -f "$backup" ]] || continue
        relative=${backup#"$theme_backup"/}
        current="$preferences/$relative"
        if [[ ! -f "$current" ]] || ! /usr/bin/cmp -s "$backup" "$current"; then
            if ! /bin/mkdir -p "${current%/*}" || ! /bin/cp -p "$backup" "$current"; then
                printf 'Could not restore theme preferences from %s to %s\n' "$backup" "$current" >&2
                failed=true
            fi
        fi
    done
    for current in "$preferences"/local/*/appearance/prefs.plist; do
        [[ -f "$current" ]] || continue
        relative=${current#"$preferences"/}
        [[ -f "$theme_backup/$relative" ]] && continue
        if ! /usr/bin/plutil -lint "$current" >/dev/null; then
            printf 'Could not inspect new Alfred preferences file %s\n' "$current" >&2
            failed=true
        elif /usr/bin/plutil -extract lightthemeuid raw -o - "$current" >/dev/null 2>&1; then
            if ! /usr/bin/plutil -remove lightthemeuid "$current"; then
                printf 'Could not remove temporary theme setting from %s\n' "$current" >&2
                failed=true
            fi
        fi
    done
    ! $failed
}

stop_alfred() {
    local attempt
    if /usr/bin/pgrep -x Alfred >/dev/null 2>&1; then
        /usr/bin/osascript -e 'tell application id "com.runningwithcrayons.Alfred" to quit' || :
    fi
    for ((attempt = 0; attempt < 300; attempt++)); do
        /usr/bin/pgrep -x Alfred >/dev/null 2>&1 || return 0
        /bin/sleep 0.1
    done
    printf '%s\n' 'Alfred did not quit; theme settings were left untouched to avoid a save race.' >&2
    return 1
}

cleanup() {
    local status=$? restore_failed=false alfred_touched=false
    if $restore_demo; then
        alfred_touched=true
        /bin/cp "$work/demo-original.plist" "$installed/info.plist" && reload "$bundle" || restore_failed=true
    fi
    if $restore_production; then
        alfred_touched=true
        local index
        for ((index = 0; index < production_count; index++)); do
            if /bin/cp "${production_backups[$index]}" "${production_paths[$index]}"; then
                reload "${production_bundles[$index]}" || restore_failed=true
            else
                restore_failed=true
            fi
        done
    fi
    if $restore_theme; then
        alfred_touched=true
    fi
    if $alfred_touched; then
        if stop_alfred; then
            if $restore_theme && ! restore_theme_preferences; then
                restore_failed=true
            fi
        else
            restore_failed=true
        fi
    fi
    if $restore_failed; then
        printf 'Could not fully restore Alfred settings. Recovery files: %s\n' "$work" >&2
        exit 1
    fi
    if ! /bin/rm -r "$work"; then
        printf 'Could not remove temporary files. Recovery files: %s\n' "$work" >&2
        exit 1
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

npm run package
payload="$work/workflow"
/usr/bin/unzip -q dist/hubfred.alfredworkflow -d "$payload"
/bin/cp scripts/screenshots/fixtures.json "$payload/fixtures.json"
/bin/mv "$payload/search.sh" "$payload/search-live.sh"
/bin/cat > "$payload/search.sh" <<'BASH'
#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
export TZ=UTC alfred_workflow_cache="$HOME/Library/Caches/org.hubfred.screenshots"
gh() {
    [[ "$#" == 11 && "$1" == search && "$4 $5 $6 $7 $8 $9 ${10}" == '--state open --sort updated --limit 1000 --json' ]] || return 2
    /usr/bin/jq -ce --arg kind "$2" --arg query "$3" '.[$kind][$query] // error("Unexpected screenshot query")' fixtures.json
}
source ./search-live.sh
BASH
# Both dashboard actions use this private cache and never inspect CLI credentials.
/usr/bin/shasum -a 256 "$payload/fixtures.json" | {
    read -r checksum _
    printf 'export GH_TOKEN=%s\n' "$checksum"
    printf '%s\n' 'export alfred_workflow_cache="$HOME/Library/Caches/org.hubfred.screenshots"'
} > "$work/cache-prefix"
/bin/cat "$work/cache-prefix" "$payload/prs.alfredui/cache.sh" > "$work/cache.sh"
/bin/mv "$work/cache.sh" "$payload/prs.alfredui/cache.sh"

/usr/bin/plutil -convert json -o - "$payload/info.plist" | /usr/bin/jq --arg bundle "$bundle" '
    .bundleid = $bundle | .name = "hubfred screenshots" | .readme = "Offline screenshot fixtures only."
    | ([.objects[] | select(.type == "alfred.workflow.action.openurl") | .uid]) as $unused
    | .objects |= map(select(.uid as $id | $unused | index($id) | not))
    | .connections |= with_entries(select(.value[0].destinationuid as $id | $unused | index($id) | not))
    | .uidata |= with_entries(select(.key as $id | $unused | index($id) | not))
    | (.objects[] | select(.config.keyword == "pr" or .config.keyword == "is").config.keyword) += "-demo"
    | (.objects[] | select(.config.keyword == "prs" or .config.keyword == "iss")) |= (
        .config.keyword as $keyword
        | .type = "alfred.workflow.trigger.external"
        | .config = {triggerid: (if $keyword == "prs" then "pr-dashboard" else "issue-dashboard" end), availableviaurlhandler: false}
    )
' > "$work/info.json"
/usr/bin/plutil -convert xml1 -o "$payload/info.plist" "$work/info.json"

if [[ "${1:-}" == --prepare ]]; then
    (cd "$payload" && /usr/bin/zip -q -X -r "$work/hubfred-screenshots.alfredworkflow" .)
    /bin/mv -f "$work/hubfred-screenshots.alfredworkflow" "$archive"
    printf 'Open %s in Alfred once, then run npm run screenshots.\n' "$archive"
    exit 0
fi

workflows="${HUBFRED_ALFRED_WORKFLOWS:-$HOME/Library/Application Support/Alfred/Alfred.alfredpreferences/workflows}"
if [[ "$(/usr/bin/defaults read -g AppleInterfaceStyle 2>/dev/null || :)" == Dark ]]; then
    printf '%s\n' 'Set macOS to Light Mode before capturing screenshots; this command does not change macOS appearance.' >&2
    exit 1
fi
preferences="$(/usr/bin/dirname "$workflows")/preferences"
for plist in "$workflows"/*/info.plist; do
    workflow_bundle=$(/usr/libexec/PlistBuddy -c 'Print :bundleid' "$plist" 2>/dev/null || :)
    case "$workflow_bundle" in
        "$bundle") installed=${plist%/info.plist} ;;
        "$production_bundle"|"$legacy_production_bundle")
            production_paths[$production_count]=$plist
            production_bundles[$production_count]=$workflow_bundle
            production_count=$((production_count + 1))
            ;;
    esac
done
if [[ -z "$installed" ]]; then
    printf '%s\n' 'Run npm run screenshots -- --prepare and import the generated demo workflow first.' >&2
    exit 1
fi

theme_backup="$work/theme-preferences"
if ! backup_theme_preferences; then
    printf 'Could not back up Alfred theme preferences under %s; no Alfred settings were changed.\n' "$preferences" >&2
    exit 1
fi

/bin/mkdir "$work/images"
/bin/cp -p "$installed/info.plist" "$work/demo-original.plist"
restore_demo=true
/usr/bin/ditto "$payload" "$installed"
for ((index = 0; index < production_count; index++)); do
    production_backup="$work/production-$index.plist"
    /bin/cp -p "${production_paths[$index]}" "$production_backup"
    production_backups[$index]=$production_backup
    /usr/bin/plutil -convert json -o - "$production_backup" | /usr/bin/jq '
        (.objects[] | select(.config.keyword == "pr" or .config.keyword == "is").config.keyword)
        |= ("hubfred-capture-disabled-" + .)
    ' > "$work/production-$index.json"
done
if ((production_count > 0)); then
    restore_production=true
    for ((index = 0; index < production_count; index++)); do
        /usr/bin/plutil -convert xml1 -o "${production_paths[$index]}" "$work/production-$index.json"
        reload "${production_bundles[$index]}"
    done
fi

/usr/bin/plutil -convert json -o - "$payload/info.plist" | /usr/bin/jq '
    (.objects[] | select(.config.keyword == "pr-demo" or .config.keyword == "is-demo").config.keyword)
    |= rtrimstr("-demo")
' > "$work/demo.json"
/usr/bin/plutil -convert xml1 -o "$installed/info.plist" "$work/demo.json"
reload "$bundle"
restore_theme=true
/usr/bin/osascript -e 'tell application id "com.runningwithcrayons.Alfred" to set theme "Alfred Classic"'
/usr/bin/swift scripts/screenshots/capture.swift "$work/images"
/bin/mkdir -p docs/screenshots
/bin/cp "$work/images/"{picker,pr-dashboard,issue-picker,dashboard}.png docs/screenshots/
