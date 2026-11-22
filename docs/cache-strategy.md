# Cache Strategy

## Performance

- The workflow manages the caches for pickers (`pr`, `is`, `gh`) and dashboards (`prs`, `iss`, `ghs`) without using Alfred's built-in result cache. They share the SQLite cache format and freshness rules. Each view has its own cache file, which the workflow replaces atomically on refresh. If refreshes overlap, the last successful replacement wins.
- If the credential matches and the cache is younger than `CACHE_FRESH_SECONDS`, the workflow skips the fetch. When a fetch is due, it shows the cached list first if the credential matches and the cache is younger than `CACHE_STALE_SECONDS` when the refresh starts. The list stays visible during the refresh and remains visible if the fetch fails and the credential hasn't changed. Without a usable cache, the view waits for new results and shows an error if the fetch fails. Expiration does not delete the cache. Both thresholds are defined in [cache-decisions.sh](../workflow/prs.alfredui/cache-decisions.sh).
- When a picker shows a stale list, Alfred reruns the Script Filter once to refresh it.
- On launch, dashboards read only the list. The asynchronous refresh then reads only the cache metadata to decide whether to fetch. The preview reads the selected item's description from a separate table indexed by URL, without making a network request.
- Generated Octicon PNGs are cached in `octicons-v5` and reused across accounts.

## Security

- The cache key is the SHA-256 hash of the token used for `github.com`. The workflow checks `GH_TOKEN`, then `GITHUB_TOKEN`, and uses the first nonempty value. If neither is set to a nonempty value, it uses the output of the local `gh auth token --hostname github.com` command. The cache stores the hash, not the token itself. The workflow passes the raw token to `search.sh` through the `GH_TOKEN` environment variable.
- Pickers and dashboards use only caches that match the resolved credential. If the credential can't be resolved or changes during a refresh, the view clears the old list and shows an error. Dashboards also clear the preview. Results fetched with the old credential are neither displayed nor stored.
- Lists and dashboard descriptions are stored unencrypted under `$alfred_workflow_cache`. If that variable is unset, the workflow uses `$HOME/Library/Caches/jp.kasutera.hubfred`. It creates new cache directories and database files with `umask 077` and leaves existing directory permissions unchanged.
- The screenshot workflow has a separate bundle ID and stores its cache at `$HOME/Library/Caches/org.hubfred.screenshots`. It uses synthetic data and does not connect to GitHub.
