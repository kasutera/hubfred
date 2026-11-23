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
capture_started=false
restore_demo=false
restore_production=false

reload() {
    /usr/bin/osascript -e "tell application id \"com.runningwithcrayons.Alfred\" to reload workflow \"$1\""
}

cleanup() {
    local status=$? restore_failed=false
    trap '' INT TERM HUP
    if $restore_demo; then
        /bin/cp "$work/demo-original.plist" "$installed/info.plist" && reload "$bundle" || restore_failed=true
    fi
    if $restore_production; then
        local index
        for ((index = 0; index < production_count; index++)); do
            if /bin/cp "${production_backups[$index]}" "${production_paths[$index]}"; then
                reload "${production_bundles[$index]}" || restore_failed=true
            else
                restore_failed=true
            fi
        done
    fi
    if $capture_started && ! /usr/bin/swift scripts/screenshots/capture.swift --dismiss; then
        printf '%s\n' 'Could not dismiss Alfred after capture.' >&2
        restore_failed=true
    fi
    if $restore_failed; then
        printf 'Could not complete screenshot cleanup. Recovery files: %s\n' "$work" >&2
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

if [[ "${1:-}" != --prepare ]]; then
    workflows="${HUBFRED_ALFRED_WORKFLOWS:-$HOME/Library/Application Support/Alfred/Alfred.alfredpreferences/workflows}"
    if [[ ! -d "$workflows" ]]; then
        printf 'Alfred workflows directory does not exist: %s\n' "$workflows" >&2
        exit 1
    fi
    # Lock the directory itself so aliases contend and no lock file needs cleanup.
    # Bash keeps the descriptor open through the EXIT trap, including restoration.
    exec 9<"$workflows"
    /usr/bin/perl -MFcntl=:flock -MErrno=EWOULDBLOCK -e '
        exit 0 if flock(STDIN, LOCK_EX | LOCK_NB);
        die "Another screenshot capture is already running for $ARGV[0].\n"
            if $! == EWOULDBLOCK;
        die "Could not lock Alfred workflows directory $ARGV[0]: $!\n";
    ' -- "$workflows" <&9 9<&-
fi

npm run package
payload="$work/workflow"
/usr/bin/unzip -q dist/hubfred.alfredworkflow -d "$payload"
/bin/mv "$payload/prs.alfredui/load.sh" "$payload/prs.alfredui/load-live.sh"
/bin/mkdir "$payload/demo-bin"
/bin/cp scripts/screenshots/fixtures.json "$payload/demo-bin/"
/usr/bin/install -m 755 scripts/screenshots/gh "$payload/demo-bin/gh"
/bin/cat > "$payload/prs.alfredui/load.sh" <<'BASH'
#!/bin/bash
set -euo pipefail
entry_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
demo_bin="$entry_dir/../demo-bin"
[[ -x "$demo_bin/gh" ]] || exit 1
checksum=$(/usr/bin/shasum -a 256 "$demo_bin/fixtures.json")
export GH_TOKEN="${checksum%% *}" TZ=UTC
export alfred_workflow_cache="$HOME/Library/Caches/org.hubfred.screenshots"
export PATH="$demo_bin:/usr/bin:/bin"
exec /bin/bash "$entry_dir/load-live.sh" "$@"
BASH
/bin/chmod 755 "$payload/prs.alfredui/load.sh"
/usr/bin/plutil -convert json -o - "$payload/info.plist" | /usr/bin/jq --arg bundle "$bundle" '
    .bundleid = $bundle | .name = "hubfred screenshots" | .readme = "Offline screenshot fixtures only."
    | ([.objects[] | select(.type == "alfred.workflow.action.openurl") | .uid]) as $unused
    | .objects |= map(select(.uid as $id | $unused | index($id) | not))
    | .connections |= with_entries(select(.value[0].destinationuid as $id | $unused | index($id) | not))
    | .uidata |= with_entries(select(.key as $id | $unused | index($id) | not))
    | (.userconfigurationconfig | map({key: ("{var:" + .variable + "}"), value: .config.default}) | from_entries) as $defaults
    | del(.userconfigurationconfig)
    | .objects |= map(
        ($defaults[.config.keyword // ""] // "") as $keyword
        | if .type == "alfred.workflow.input.scriptfilter" and $keyword != "" then
            .config.keyword = ($keyword + "-demo")
          elif .type == "alfred.workflow.input.keyword" and $keyword != "" then
            .type = "alfred.workflow.trigger.external"
            | .config = {triggerid: ({prs: "pr-dashboard", iss: "issue-dashboard", ghs: "github-dashboard"}[$keyword]), availableviaurlhandler: false}
          else . end
    )
' > "$work/info.json"
/usr/bin/plutil -convert xml1 -o "$payload/info.plist" "$work/info.json"

if [[ "${1:-}" == --prepare ]]; then
    (cd "$payload" && /usr/bin/zip -q -X -r "$work/hubfred-screenshots.alfredworkflow" .)
    /bin/mv -f "$work/hubfred-screenshots.alfredworkflow" "$archive"
    printf 'Open %s in Alfred once, then run npm run screenshots.\n' "$archive"
    exit 0
fi

if [[ "$(/usr/bin/defaults read -g AppleInterfaceStyle 2>/dev/null || :)" == Dark ]]; then
    printf '%s\n' 'Set macOS to Light Mode and Alfred to the Alfred Classic theme before capturing; this command does not change either setting.' >&2
    exit 1
fi
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

/bin/mkdir "$work/images"
/bin/cp -p "$installed/info.plist" "$work/demo-original.plist"
restore_demo=true
/usr/bin/ditto "$payload" "$installed"
for ((index = 0; index < production_count; index++)); do
    production_backup="$work/production-$index.plist"
    /bin/cp -p "${production_paths[$index]}" "$production_backup"
    production_backups[$index]=$production_backup
    /usr/bin/plutil -convert json -o - "$production_backup" | /usr/bin/jq '
        .objects |= map(
            if ((.type == "alfred.workflow.input.scriptfilter" or .type == "alfred.workflow.input.keyword")
                and (.config | has("keyword")))
            then .config.keyword = "hubfred-capture-disabled-" + (.uid | ascii_downcase)
            else .
            end
        )
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
    (.objects[] | select(.type == "alfred.workflow.input.scriptfilter").config.keyword)
    |= rtrimstr("-demo")
' > "$work/demo.json"
/usr/bin/plutil -convert xml1 -o "$installed/info.plist" "$work/demo.json"
reload "$bundle"
capture_started=true
/usr/bin/swift scripts/screenshots/capture.swift "$work/images"
/bin/mkdir -p docs/screenshots
/bin/cp "$work/images/"{picker,pr-dashboard,issue-picker,dashboard,github-picker,github-dashboard}.png docs/screenshots/
