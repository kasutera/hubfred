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
npm run typecheck

mkdir -p dist
stage=$(mktemp -d "$PWD/dist/.package.XXXXXX")
trap 'rm -r "$stage"' EXIT
payload="$stage/payload"
mkdir "$payload"

# Use worktree contents of indexed files, never local caches or Finder metadata.
git ls-files -z -- workflow/ ':(exclude)workflow/prs.alfredui/vendor/marked/**' \
    ':(exclude)workflow/prs.alfredui/render-markdown.js' \
    | while IFS= read -r -d '' source; do
        # A tracked source removed from the worktree is not part of this build.
        [[ -e "$source" || -L "$source" ]] || continue
        if [[ ! -f "$source" || -L "$source" ]]; then
            printf 'Expected a regular workflow source: %s\n' "$source" >&2
            exit 1
        fi
        [[ "${source##*/}" != .DS_Store ]] || continue
        target="$payload/${source#workflow/}"
        mkdir -p "${target%/*}"
        cp -p "$source" "$target"
    done

for arch in arm64 amd64; do
    CGO_ENABLED=0 GOOS=darwin GOARCH=$arch go build -buildvcs=false -trimpath -ldflags='-s -w' \
        -o "$payload/prs.alfredui/dashboard-$arch" ./cmd/dashboard
done

renderer="$payload/prs.alfredui/render-markdown.js"
node_modules/.bin/esbuild scripts/render-markdown.ts --bundle --format=iife \
    --global-name=hubfredMarkdown --target=es2020 \
    --banner:js='function run(argv) { return hubfredMarkdown.run(argv); }' \
    --outfile="$renderer"
cp LICENSE "$payload/LICENSE"
go_license="$(go env GOROOT)/LICENSE"
# Homebrew installs the license beside libexec rather than inside GOROOT.
if [ ! -f "$go_license" ]; then
    go_license="$(dirname "$(dirname "$go_license")")/LICENSE"
fi
cp "$go_license" "$payload/LICENSE.go"
text_module_dir=$(go list -m -f '{{.Dir}}' golang.org/x/text)
cp "$text_module_dir/LICENSE" "$payload/LICENSE.go-x-text"
vendor="$payload/prs.alfredui/vendor/marked"
mkdir -p "$vendor"
cp node_modules/marked/lib/marked.umd.js node_modules/marked/LICENSE "$vendor/"

(cd "$payload" && zip -q -X -r "$stage/hubfred.alfredworkflow" .)
mv -f "$stage/hubfred.alfredworkflow" dist/hubfred.alfredworkflow
printf 'Built %s\n' dist/hubfred.alfredworkflow
