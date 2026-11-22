# Maintainer Guide

## Local Development

The workflow requires macOS 15 or later to run. The package can also be built on Linux, as in CI. Build from the repository root using Node.js 24, npm, and `zip`; Node.js is build and test tooling only, and the packaged workflow does not require Node.js. Run `npm ci` on the first setup and whenever the lockfile changes.

```bash
npm ci --ignore-scripts
npm test
open dist/hubfred.alfredworkflow
```

`npm test` runs the package build before executing tests. Use `npm run package` directly when you only need to build a distributable archive, including on Linux.

`npm run package` reads files under `workflow/` from the working tree for files tracked in the Git index, so it includes uncommitted changes to existing files. Newly added files must be tracked by Git first. Marked's JavaScript and license are bundled only in the package, from the locked npm distribution. TypeScript sources under `scripts/` are type-checked with `npm run typecheck` and bundled into the generated JXA renderer in package staging; neither TypeScript source nor development tooling is included in the workflow. ES2020 is a JXA compatibility target matching the original syntax, not a Node.js target.

On macOS 15 or later, `npm test` builds the package and exercises search formatting, dashboard refresh decisions, and the production JXA Markdown renderer from that package with the locked Marked library. It also tests the sanitizer directly through Foundation in a test-only bundle. The sanitizer wrapper declares UTF-8 before its body because Foundation's TidyHTML parser needs the charset before parsing non-ASCII Markdown. Tests use synthetic GitHub CLI responses and do not require GitHub credentials or Alfred.

## README Screenshots

Use macOS 15 or later, Alfred 6, and Swift (Xcode Command Line Tools). Grant Terminal permission to record the screen and control Alfred and Finder. Set macOS to Light Mode and manually select the **Alfred Classic** theme before capture; the command leaves both settings unchanged. The README images were captured at Retina (2×) resolution.

```bash
npm ci --ignore-scripts
npm run screenshots -- --prepare
open dist/hubfred-screenshots.alfredworkflow
npm run screenshots
```

Run `--prepare` and import the workflow only once. `--prepare` only builds the archive; it does not take screenshots, change Alfred settings, or quit Alfred. On subsequent runs, `npm run screenshots` updates the screenshot-only workflow and writes four PNGs to `docs/screenshots/`: simplified PR/Issue lists and dashboards. Any PR that changes the workflow's appearance must rerun `npm run screenshots` and include the regenerated screenshots. If Alfred settings are synced, set `HUBFRED_ALFRED_WORKFLOWS` to the synced `Alfred.alfredpreferences/workflows` directory. The command does not migrate or remove older workflows or artifacts.

Captures use synthetic data from `scripts/screenshots/fixtures.json` and a fixed UTC timestamp. The screenshot workflow uses a Bundle ID and cache separate from production and does not connect to GitHub CLI. Verify that the target window shows synthetic data, then save PNGs without shadows and with transparent corners outside the rounded window. Use Alfred Classic to match the existing images; pixel-level results can still vary by OS. The screenshot workflow and data are excluded from release packages.

Only one capture can run against the same Alfred workflows directory at a time, even when it is reached through different paths. A competing capture fails immediately without touching settings. The lock is held from before keyword backup until restoration and window dismissal are complete.

During capture, installed production workflows under the current or legacy Bundle IDs have their `pr` and `is` keywords temporarily backed up and disabled, and the screenshot workflow responds to those keywords. They are restored on normal completion, failure, or ordinary interruption. After capture starts, the command activates Finder only if a visible Alfred capture window remains; Alfred is never quit. The theme and Alfred preference files are not modified. If workflow restoration fails, the command prints the recovery-file location. Do not edit Alfred workflow settings during capture.

## Runtime Behavior

- Searches run in parallel for each participation category. The `pr` and `is` pickers fetch up to 10 results per category, then combine and deduplicate them to show the 10 most recently updated items. The `prs` and `iss` dashboards fetch up to 1,000 results per category (the GitHub Search limit per query), then combine and deduplicate them in update-time order. Update times are shown in the Mac's local time.
- The bundled [Marked](https://github.com/markedjs/marked) converts GFM for display in WebKit. Marked's output is reconstructed from allowed elements, attributes, and URLs; arbitrary raw HTML is not passed through, and images are shown as links instead of loaded inline. Conversion allows up to 128 KiB of UTF-8 input on stdin, 128 columns per GFM table, 8,192 table cells across the document (including headers and cells added to fill short rows), and 512 KiB of UTF-8 HTML output. If conversion exceeds any of these limits or times out after 2 seconds, the preview directs readers to open the item on GitHub.

## Cache Strategy

See [Cache Strategy](docs/cache-strategy.md) for cache performance and security behavior.

## CI and Releases

Dependabot PRs and pushes to `main` generate an `.alfredworkflow` file that can be downloaded as an Actions artifact. Bundled files do not need to be updated manually.

To publish a release, update `version` in `workflow/info.plist`, then push a `v`-prefixed tag with the same version. The release is published on GitHub Releases. It will not be published if the tag and workflow versions do not match. The distribution includes the app and the Octicons and Marked licenses.
