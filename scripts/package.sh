#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."

node -e '
    const locked = require("./package-lock.json").packages["node_modules/marked"].version;
    try {
        if (require("./node_modules/marked/package.json").version === locked) process.exit(0);
    } catch (error) {
        if (error.code !== "MODULE_NOT_FOUND") throw error;
    }
    console.error("Run npm ci --ignore-scripts to install the locked version of Marked.");
    process.exit(1);
'

mkdir -p dist
stage=$(mktemp -d "$PWD/dist/.package.XXXXXX")
trap 'rm -r "$stage"' EXIT
payload="$stage/payload"
mkdir "$payload"

# Use worktree contents of indexed files, never local caches or Finder metadata.
git ls-files -z -- workflow/ ':(exclude)workflow/prs.alfredui/vendor/marked/**' \
    | while IFS= read -r -d '' source; do
        if [[ ! -f "$source" || -L "$source" ]]; then
            printf 'Expected a regular workflow source: %s\n' "$source" >&2
            exit 1
        fi
        [[ "${source##*/}" != .DS_Store ]] || continue
        target="$payload/${source#workflow/}"
        mkdir -p "${target%/*}"
        cp -p "$source" "$target"
    done

cp LICENSE "$payload/LICENSE"
vendor="$payload/prs.alfredui/vendor/marked"
mkdir -p "$vendor"
cp node_modules/marked/lib/marked.umd.js node_modules/marked/LICENSE "$vendor/"

(cd "$payload" && zip -q -X -r "$stage/hubfred.alfredworkflow" .)
mv -f "$stage/hubfred.alfredworkflow" dist/hubfred.alfredworkflow
printf 'Built %s\n' dist/hubfred.alfredworkflow
