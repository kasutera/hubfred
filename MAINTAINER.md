# Maintainer Guide

## Local Development

Build from the repository root using Node.js 24, npm, and `zip`. Run `npm ci` on the first setup and whenever the lockfile changes.

```bash
npm ci --ignore-scripts
npm run package
open dist/Hubfred.alfredworkflow
```

`npm run package` reads files under `workflow/` from the working tree for files tracked in the Git index, so it includes uncommitted changes to existing files. Newly added files must be tracked by Git first. Marked's JavaScript and license are bundled only in the package, from the locked npm distribution.

## README Screenshots

Use Alfred 6 and Swift (Xcode Command Line Tools) on macOS. Grant Terminal permission to record the screen and control Alfred. Set macOS to Light Mode and Alfred's theme to **Alfred Classic** while capturing. The README images were captured at Retina (2×) resolution.

```bash
npm ci --ignore-scripts
npm run screenshots -- --prepare
open dist/Hubfred-Screenshots.alfredworkflow
npm run screenshots
```

Run `--prepare` and import the workflow only once. On subsequent runs, `npm run screenshots` updates the screenshot-only workflow and writes four PNGs to `docs/screenshots/`: simplified PR/Issue lists and dashboards. Any PR that changes the workflow's appearance must rerun `npm run screenshots` and include the regenerated screenshots. If Alfred settings are synced, set `HUBFRED_ALFRED_WORKFLOWS` to the synced `Alfred.alfredpreferences/workflows` directory.

Captures use synthetic data from `scripts/screenshots/fixtures.json` and a fixed UTC timestamp. The screenshot workflow uses a Bundle ID and cache separate from production and does not connect to GitHub CLI. Verify that the target window shows synthetic data, then save PNGs without shadows and with transparent corners outside the rounded window. Pixel-level results may vary by theme and OS. The screenshot workflow and data are excluded from release packages.

During capture, the production `pr` and `is` keywords are temporarily backed up, and the screenshot workflow responds to those keywords. They are restored on normal completion, failure, or ordinary interruption. If restoration fails, the command prints the backup location. Do not edit Alfred settings during capture.

## Runtime Behavior

- `pr` and `is` use Alfred's cache. Reopening them more than 30 seconds after the previous fetch triggers a background refresh. To clear the cache after switching GitHub CLI accounts, run `reload` in Alfred.
- `prs` and `iss` store the list and body separately on disk. For up to 30 seconds, they do not fetch again; from 30 seconds to under 10 minutes, they show the previous list while refreshing in the background. A failed refresh leaves the old list intact. On the first load, after 10 minutes, or after authentication settings change, they wait for GitHub's response. Ten minutes is the display freshness window, not a deletion deadline.
- Searches run in parallel for each participation category, and results are sorted by update time. GitHub Search is limited to 1,000 results per search query. Icons use [Octicons v19.19.0](https://github.com/primer/octicons/tree/v19.19.0/icons), tinted in 12 colors. Update times are shown in the Mac's local time.
- The bundled [Marked](https://github.com/markedjs/marked) converts GFM to HTML for display in WebKit. Raw HTML and images are not rendered; images can be opened as links. If the conversion process times out after 2 seconds, the item can still be opened on GitHub.

## CI and Releases

Dependabot PRs and pushes to `main` generate an `.alfredworkflow` file that can be downloaded as an Actions artifact. Bundled files do not need to be updated manually.

To publish a release, update `version` in `workflow/info.plist`, then push a `v`-prefixed tag with the same version. The release is published on GitHub Releases. It will not be published if the tag and workflow versions do not match. The distribution includes the app and the Octicons and Marked licenses.
