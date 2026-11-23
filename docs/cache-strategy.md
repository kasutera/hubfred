# Cache Strategy

## Performance

- The workflow manages picker and dashboard snapshots in SQLite without using Alfred's built-in result cache. A filtered picker uses a broad snapshot, independent of the dashboard settings. Dashboards share that snapshot only at the full search limit with no date filter. Otherwise each dashboard kind keeps one scoped snapshot and reuses it only for matching settings. Each successful save replaces the snapshot atomically.
- When the credential matches, a snapshot younger than `CACHE_FRESH_SECONDS` skips the fetch. If it is younger than `CACHE_STALE_SECONDS`, the view can show it during a refresh. Both thresholds are defined in [cache.sh](../workflow/prs.alfredui/cache.sh). A dashboard with a date filter also drops cached rows that are now outside the configured window.
- Snapshots with invalid list rows or timestamps in the future are treated as cache misses.
- A filtered picker reads only the list and applies the query before taking the latest matches. Alfred reruns the Script Filter once to refresh a stale list or fetch a missing one.
- A dashboard without a usable snapshot can show the matching unfiltered picker list while GitHub search runs. It then replaces it with the merged first pages and loads any remaining pages up to the configured limit. It publishes the list before saving the full snapshot; neither the picker fallback nor an incomplete fetch overwrites the snapshot.
- GitHub returns descriptions with the search pages. After the dashboard saves the snapshot, the preview reads the selected description by URL from the separate `bodies` table without another network request.
- Generated Octicon PNGs are cached in `octicons-v5` and reused across accounts.

## Security

- The cache key is derived from the SHA-256 hash of the token used for `github.com`. The workflow checks `GH_TOKEN`, then `GITHUB_TOKEN`, and uses the first nonempty value. If neither is set to a nonempty value, it uses the output of the local `gh auth token --hostname github.com` command. The cache stores the hash, not the token itself. The workflow passes the raw token to the GitHub CLI through `GH_TOKEN`.
- Pickers and dashboards only reuse data for the resolved credential. The dashboard checks it between search stages and before saving. If the credential cannot be resolved or changes during a refresh, the dashboard clears its list and preview, and discards pending results.
- Lists and dashboard descriptions are stored unencrypted under `$alfred_workflow_cache`. If that variable is unset, the workflow uses `$HOME/Library/Caches/jp.kasutera.hubfred`. New snapshot directories and database files are restricted to the current user; existing directory permissions are unchanged.
- The screenshot workflow has a separate bundle ID and stores its cache at `$HOME/Library/Caches/org.hubfred.screenshots`. It uses synthetic data and does not connect to GitHub.
