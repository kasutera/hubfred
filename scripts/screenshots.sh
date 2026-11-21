#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."

bundle=org.hubfred.screenshots
production_bundle=jp.kasutera.github-prs
archive="$PWD/dist/Hubfred-Screenshots.alfredworkflow"
work=$(/usr/bin/mktemp -d)
production=
installed=
restore_demo=false
restore_production=false

reload() {
    /usr/bin/osascript -e "tell application id \"com.runningwithcrayons.Alfred\" to reload workflow \"$1\""
}

cleanup() {
    local status=$? restore_failed=false
    if $restore_demo; then
        /bin/cp "$payload/info.plist" "$installed/info.plist" && reload "$bundle" || restore_failed=true
    fi
    if $restore_production; then
        /bin/cp "$work/production.plist" "$production" && reload "$production_bundle" || restore_failed=true
    fi
    if $restore_failed; then
        printf 'Could not restore or reload Alfred settings. Recovery files: %s\n' "$work" >&2
        exit 1
    fi
    /bin/rm -r "$work"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

npm run package
payload="$work/workflow"
/usr/bin/unzip -q dist/Hubfred.alfredworkflow -d "$payload"
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
    .bundleid = $bundle | .name = "Hubfred Screenshots" | .readme = "Offline screenshot fixtures only."
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
    (cd "$payload" && /usr/bin/zip -q -X -r "$work/Hubfred-Screenshots.alfredworkflow" .)
    /bin/mv -f "$work/Hubfred-Screenshots.alfredworkflow" "$archive"
    printf 'Open %s in Alfred once, then run npm run screenshots.\n' "$archive"
    exit 0
fi

workflows="${HUBFRED_ALFRED_WORKFLOWS:-$HOME/Library/Application Support/Alfred/Alfred.alfredpreferences/workflows}"
for plist in "$workflows"/*/info.plist; do
    case "$(/usr/libexec/PlistBuddy -c 'Print :bundleid' "$plist" 2>/dev/null || :)" in
        "$bundle") installed=${plist%/info.plist} ;;
        "$production_bundle") production=$plist ;;
    esac
done
if [[ -z "$installed" ]]; then
    printf '%s\n' 'Run npm run screenshots -- --prepare and import the generated demo workflow first.' >&2
    exit 1
fi

/bin/mkdir "$work/images"
/usr/bin/ditto "$payload" "$installed"
if [[ -n "$production" ]]; then
    /bin/cp -p "$production" "$work/production.plist"
    /usr/bin/plutil -convert json -o - "$work/production.plist" | /usr/bin/jq '
        (.objects[] | select(.config.keyword == "pr" or .config.keyword == "is").config.keyword)
        |= ("hubfred-capture-disabled-" + .)
    ' > "$work/production.json"
    restore_production=true
    /usr/bin/plutil -convert xml1 -o "$production" "$work/production.json"
    reload "$production_bundle"
fi

/usr/bin/plutil -convert json -o - "$payload/info.plist" | /usr/bin/jq '
    (.objects[] | select(.config.keyword == "pr-demo" or .config.keyword == "is-demo").config.keyword)
    |= rtrimstr("-demo")
' > "$work/demo.json"
restore_demo=true
/usr/bin/plutil -convert xml1 -o "$installed/info.plist" "$work/demo.json"
reload "$bundle"
/usr/bin/swift scripts/screenshots/capture.swift "$work/images"
/bin/mkdir -p docs/screenshots
/bin/cp "$work/images/"{picker,pr-dashboard,issue-picker,dashboard}.png docs/screenshots/
