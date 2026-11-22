# Cache Strategy

## Performance

- **Pickers (`pr`, `is`):** Alfred caches results for 30 seconds. With `loosereload`, it can show cached results while refreshing in the background.
- **Dashboards (`prs`, `iss`):** Each has its own SQLite cache (`dashboard-v3.sqlite3` and `issues-dashboard-v3.sqlite3`). On launch, preload reads only the list; the asynchronous refresh checks only metadata before deciding whether to fetch. The preview reads the selected description from a separate table indexed by URL, without a network request.
- **Dashboard freshness:** A matching snapshot younger than 30 seconds skips the fetch. From 30 seconds to under 10 minutes, the cached list stays visible during refresh and remains visible if fetching fails without an authentication change. With no matching snapshot under 10 minutes old, the dashboard waits for fresh results and shows an error if fetching fails. Expiration does not delete the snapshot.
- **Snapshot updates:** The loader atomically replaces the database so the list and descriptions are published together. Overlapping refreshes run independently; the last successful replacement wins.
- **Icons:** Generated Octicon PNGs are reused from the `octicons-v5` cache directory across accounts.

## Security

- **Dashboard identity:** The cache key is a SHA-256 digest of the effective github.com token, resolved from the first nonempty `GH_TOKEN`, then `GITHUB_TOKEN`, or the local result of `gh auth token --hostname github.com`. Only the digest is stored. The loader passes the raw token to `search.sh` through `GH_TOKEN`.
- **Dashboard isolation:** Only snapshots matching the resolved credential are used. If authentication cannot be resolved or changes during refresh, the dashboard clears the list and preview, shows an error, and does not cache the fetched results.
- **Picker limitation:** Alfred's picker cache is not credential-specific. Run `reload` in Alfred after switching GitHub CLI accounts.
- **Local storage:** Dashboard lists and descriptions persist unencrypted under `$alfred_workflow_cache`, falling back to `$HOME/Library/Caches/jp.kasutera.hubfred`. The loader uses `umask 077` for new cache directories and database files; existing directory permissions are unchanged.
- **Screenshot isolation:** The screenshot workflow uses a separate Bundle ID and `$HOME/Library/Caches/org.hubfred.screenshots`. It uses synthetic fixtures without connecting to GitHub.
