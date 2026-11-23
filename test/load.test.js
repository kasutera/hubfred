'use strict';

const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');
const { execFileSync, spawnSync } = require('node:child_process');
const { after, test } = require('node:test');
const { chmodSync, mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const packageScratch = mkdtempSync(path.join(os.tmpdir(), 'hubfred-load-package-'));
execFileSync('/usr/bin/unzip', ['-q', path.join(root, 'dist', 'hubfred.alfredworkflow'), '-d', packageScratch]);
after(() => rmSync(packageScratch, {recursive: true, force: true}));
const loader = path.join(packageScratch, 'prs.alfredui', 'load.sh');
const freshLimit = 60;
const staleLimit = 60 * 60;
const oldURL = 'https://github.com/owner/repo/pull/1';
const oldItem = {
    uid: oldURL,
    arg: oldURL,
    title: 'Old cached title',
    subtitle: 'Old cached subtitle',
    match: 'Old cached title owner/repo #1',
    icon: {path: '/tmp/old-icon.png'},
    body: 'Old cached preview',
    reasons: ['Authored'],
    labels: []
};
const fetchedItem = {
    author: {login: 'reader'},
    number: 99,
    repository: {nameWithOwner: 'owner/repo'},
    title: 'New fetched title',
    updatedAt: '2026-01-20T12:00:00Z',
    url: 'https://github.com/owner/repo/pull/99',
    isDraft: false,
    body: "New fetched preview: 日本語, 'quotes' and semi;colons.\n\nSecond paragraph."
};
const mockGh = `#!/bin/bash
set -euo pipefail

if [[ "\${1:-}" == auth && "\${2:-}" == token ]]; then
    /bin/cat "$HUBFRED_TEST_CURRENT_TOKEN_FILE"
    exit
fi

if [[ "\${1:-}" == api ]]; then
    shift
    if [[ "\${1:-}" == user ]]; then
        if [[ " $* " == *" --jq .login "* ]]; then
            printf '%s\\n' reader
        else
            printf '%s\\n' '{"login":"reader"}'
        fi
        exit
    fi

    local_arg=
    page=1
    per_page=100
    query=
    for local_arg in "$@"; do
        case "$local_arg" in
            search/issues) ;;
            q=*) query=\${local_arg#q=} ;;
            page=*) page=\${local_arg#page=} ;;
            per_page=*) per_page=\${local_arg#per_page=} ;;
        esac
    done
    [[ -n "$query" ]] || exit 2
    printf '%s\\n' "$*" >> "$HUBFRED_TEST_SEARCH_LOG"
    [[ "\${HUBFRED_TEST_SEARCH_FAIL:-false}" != true ]] || exit 1
    if [[ "$page" == 2 && "$query" == *" author:reader"* && "\${HUBFRED_TEST_RATE_LIMIT:-false}" == true && ! -e "$HUBFRED_TEST_SEARCH_LOG.throttle" ]]; then
        : > "$HUBFRED_TEST_SEARCH_LOG.throttle"
        printf 'HTTP/2.0 429 Too Many Requests\\r\\nRetry-After: 0\\r\\n\\r\\n{}'
        exit 1
    fi
    printf 'HTTP/2.0 200 OK\\r\\n\\r\\n'
    /usr/bin/jq -ce --argjson page "$page" --argjson perPage "$per_page" '
        . as $response | (.pages[$page - 1] // .results[($page - 1) * $perPage:$page * $perPage]) as $rows
        | {total_count: (if $response.pages then $response.pages | map(length) | add else $response.results | length end),
            incomplete_results: ($response.incompletePage == $page), items: ($rows | map(
                . as $item
                | {url: ("https://api.github.com/repos/" + $item.repository.nameWithOwner + "/issues/" + ($item.number | tostring)),
                    html_url: $item.url,
                    repository_url: ("https://api.github.com/repos/" + $item.repository.nameWithOwner),
                    number: $item.number, title: $item.title, user: $item.author,
                    state: "open", updated_at: $item.updatedAt,
                    labels: ($item.labels // []), body: ($item.body // "")}
                + (if ($item | has("isDraft")) then
                    {draft: $item.isDraft, pull_request: {
                        url: ("https://api.github.com/repos/" + $item.repository.nameWithOwner + "/pulls/" + ($item.number | tostring)),
                        html_url: $item.url
                    }}
                   else {} end)
            ))}
    ' "$HUBFRED_TEST_SEARCH_RESULTS"
    next_token=$(/usr/bin/jq -r '.afterSearchAuth // empty' "$HUBFRED_TEST_SEARCH_RESULTS")
    if [[ -n "$next_token" ]]; then printf '%s' "$next_token" > "$HUBFRED_TEST_CURRENT_TOKEN_FILE"; fi
    exit
fi

exit 2
`;

function cacheKey(token) {
    const hash = createHash('sha256').update(Buffer.from(`token\0${token}`)).digest('hex');
    return `${hash}  -`;
}

function sqlite(file, sql) {
    const result = spawnSync('/usr/bin/sqlite3', ['-batch', '-bail', '-init', '/dev/null', file, sql],
        {encoding: 'utf8'});
    assert.equal(result.status, 0, result.stderr);
    return result.stdout;
}

function scenario(t, {
    activeToken = 'token-a', cacheToken = 'token-a',
    searchFails = true, authAfterSearch = null, mode = 'dashboard',
    age = Math.floor((freshLimit + staleLimit) / 2), cachedRows, limit = '1000', days = '0', pages,
    rateLimited = false, incompletePage = null, results = [fetchedItem]
} = {}) {
    const directory = mkdtempSync(path.join(os.tmpdir(), 'hubfred-load-'));
    t.after(() => rmSync(directory, {recursive: true, force: true}));
    const cacheDir = path.join(directory, 'cache');
    const iconDir = path.join(cacheDir, 'octicons-v5');
    const fakeBin = path.join(directory, 'bin');
    mkdirSync(fakeBin);
    const fakeGh = path.join(fakeBin, 'gh');
    writeFileSync(fakeGh, mockGh);
    chmodSync(fakeGh, 0o755);
    mkdirSync(iconDir, {recursive: true});
    for (const color of ['AC6B49', '4269A5', 'A48332', 'B15F91', '4E94B8', '62636D']) {
        for (const state of ['ready', 'draft']) {
            writeFileSync(path.join(iconDir, `${color}-${state}.png`), 'fixture');
        }
    }

    const cacheName = mode === 'picker' ? 'pr-picker-v2.sqlite3' : 'dashboard-v3.sqlite3';
    const cacheFile = path.join(cacheDir, cacheName);
    const {body, ...oldRow} = oldItem;
    const literal = value => `'${value.replaceAll("'", "''")}'`;
    sqlite(cacheFile, `
        CREATE TABLE ${mode} (identity TEXT NOT NULL, saved_at INTEGER NOT NULL, digest TEXT NOT NULL, list TEXT NOT NULL);
        CREATE TABLE bodies (url TEXT PRIMARY KEY, body TEXT NOT NULL) WITHOUT ROWID;
        INSERT INTO ${mode} VALUES (${literal(cacheKey(cacheToken))}, unixepoch() - ${age}, 'old-result-digest',
            ${literal(JSON.stringify({items: cachedRows ?? [oldRow]}))});
        INSERT INTO bodies VALUES (${literal(oldURL)}, ${literal(JSON.stringify(body))});
    `);
    const originalCache = readFileSync(cacheFile);
    const originalCacheStats = statSync(cacheFile);
    const searchResults = path.join(directory, 'search-results.json');
    writeFileSync(searchResults, JSON.stringify({
        results,
        incompletePage,
        ...(pages ? {pages} : {}),
        ...(authAfterSearch === null ? {} : {afterSearchAuth: authAfterSearch})
    }));
    const tokenFile = path.join(directory, 'current-token');
    writeFileSync(tokenFile, activeToken);
    const searchLog = path.join(directory, 'search.log');
    const env = {
        ...process.env,
        PATH: `${fakeBin}:${process.env.PATH ?? ''}`,
        HOME: directory,
        TMPDIR: directory,
        alfred_workflow_cache: cacheDir,
        dashboard_kind: 'prs',
        hubfred_dashboard_limit: limit,
        hubfred_dashboard_days: days,
        HUBFRED_TEST_CURRENT_TOKEN_FILE: tokenFile,
        HUBFRED_TEST_SEARCH_FAIL: String(searchFails),
        HUBFRED_TEST_RATE_LIMIT: String(rateLimited),
        HUBFRED_TEST_SEARCH_LOG: searchLog,
        HUBFRED_TEST_SEARCH_RESULTS: searchResults
    };
    delete env.GH_TOKEN;
    delete env.GITHUB_TOKEN;
    delete env.hubfred_refresh_identity;
    delete env.hubfred_refresh_mode;

    function runJSON(script, args, extraEnv) {
        const result = spawnSync('/bin/bash', [script, ...args], {
            cwd: path.dirname(script),
            env: {...env, ...extraEnv},
            encoding: 'utf8',
            maxBuffer: 2 * 1024 * 1024
        });
        assert.equal(result.status, 0, result.stderr);
        return JSON.parse(result.stdout);
    }

    function runPicker(query = '', variables) {
        return runJSON(loader, ['picker', 'prs', query], variables);
    }

    let session;
    function runDashboard(phase = 'first') {
        if (phase === 'first' && session === undefined) runDashboard('cached');
        const output = runJSON(loader, [phase], {dashboard_session: session ?? ''});
        if (phase === 'cached') session = output.variables?.dashboard_session ?? '';
        return output;
    }

    return {
        cacheDir,
        cacheFile,
        originalCache,
        originalCacheStats,
        run: mode === 'picker' ? variables => runPicker('', variables) : runDashboard,
        runPicker,
        runDashboard,
        searchLog,
        currentToken() {
            return readFileSync(tokenFile, 'utf8');
        },
        searchCount() {
            try {
                return readFileSync(searchLog, 'utf8').trim().split(os.EOL).filter(Boolean).length;
            } catch (error) {
                if (error.code === 'ENOENT') return 0;
                throw error;
            }
        },
        assertNoCacheWrites() {
            assert.deepEqual(readFileSync(cacheFile), originalCache);
            const currentStats = statSync(cacheFile);
            assert.equal(currentStats.ino, originalCacheStats.ino);
            assert.equal(currentStats.mtimeMs, originalCacheStats.mtimeMs);
            assert.deepEqual(readdirSync(cacheDir).sort(), ['octicons-v5', cacheName].sort());
        }
    };
}

function assertRefreshFailure(output) {
    assert.equal(output.update.ids.prs.placeholder, 'Could not load GitHub PRs');
    assert.deepEqual(output.update.ids.prs.data.src, []);
    assert.equal(output.update.ids.preview.text, '<!doctype html><html><body></body></html>');
    assert.doesNotMatch(JSON.stringify(output), /Old cached/);
}

test('same-auth failed refresh preserves the cached display', t => {
    const testCase = scenario(t);
    assert.deepEqual(testCase.run(), {});
    // The first failure can cancel the sibling request before it reaches the fixture.
    assert.ok(testCase.searchCount() > 0);
    testCase.assertNoCacheWrites();
});

test('does not show older cached data after switching to another auth identity', t => {
    const testCase = scenario(t, {activeToken: 'token-b', cacheToken: 'token-a'});
    assert.equal(testCase.run('cached').update.ids.prs, undefined);
    assertRefreshFailure(testCase.run());
    assert.ok(testCase.searchCount() > 0);
    testCase.assertNoCacheWrites();
});

test('search fixture auth change suppresses fetched results and cache writes and clears preview', t => {
    const testCase = scenario(t, {searchFails: false, authAfterSearch: 'token-b'});
    assertRefreshFailure(testCase.run());
    assert.equal(testCase.currentToken(), 'token-b');
    assert.equal(testCase.searchCount(), 2);
    testCase.assertNoCacheWrites();
});

test('a successful one-page refresh displays before saving the body-free list and preview', t => {
    const testCase = scenario(t, {searchFails: false});
    const output = testCase.run();
    const rows = output.update.ids.prs.data.src;
    assert.equal(rows.length, 1);
    assert.equal(rows[0]['title.text'], fetchedItem.title);
    assert.equal(rows[0].uid, fetchedItem.url);
    assert.equal(rows[0].previewState, 'pending');
    assert.equal(output.pulse.args[0], 'save');
    assert.equal(testCase.currentToken(), 'token-a');
    assert.equal(testCase.searchCount(), 2);
    testCase.assertNoCacheWrites();

    const saved = testCase.run('save').update.ids.prs.data.src;
    assert.equal(saved[0].previewState, 'ready');
    assert.equal(saved[0].uid, fetchedItem.url);
    assert.deepEqual(testCase.run('cached').update.ids.prs.data.src, saved);
    assert.deepEqual(testCase.run('first'), {});
    assert.equal(testCase.searchCount(), 2);
    const persistedList = JSON.parse(sqlite(testCase.cacheFile, 'SELECT list FROM dashboard;'));
    assert.equal(persistedList.items[0].body, undefined);
    const persistedBody = JSON.parse(sqlite(testCase.cacheFile, 'SELECT body FROM bodies;'));
    assert.equal(persistedBody, fetchedItem.body);
});

test('a cold dashboard displays page one without waiting for or saving page two', t => {
    const row = index => ({...fetchedItem, number: 200 + index,
        url: `https://github.com/owner/repo/pull/${200 + index}`});
    const first = Array.from({length: 100}, (_, index) => row(index));
    const testCase = scenario(t, {searchFails: false, limit: '101', pages: [first, [row(100), row(101)]], rateLimited: true});
    const initial = testCase.run('cached');
    assert.equal(initial.update.ids.prs, undefined);
    const page = testCase.run();
    assert.equal(page.pulse.args[0], 'more');
    assert.equal(page.update.ids.prs.data.src.length, 100);
    assert.equal(testCase.searchCount(), 2);
    testCase.assertNoCacheWrites();
    const final = testCase.run('more');
    assert.equal(final.pulse.args[0], 'save');
    assert.equal(final.update.ids.prs.data.src.length, 101);
    assert.ok(final.update.ids.prs.data.src.some(item => item.uid === row(100).url));
    assert.ok(!final.update.ids.prs.data.src.some(item => item.uid === row(101).url));
    assert.equal(testCase.searchCount(), 5);
    const log = readFileSync(testCase.searchLog, 'utf8').trim().split('\n');
    assert.equal(log.filter(line => /\bpage=1\b/.test(line)).length, 2);
    assert.equal(log.filter(line => /\bpage=2\b/.test(line)).length, 3);
    testCase.assertNoCacheWrites();
    const saved = testCase.run('save');
    assert.equal(saved.update.ids.prs.data.src.length, 101);
    assert.equal(testCase.run('cached').update.ids.prs.data.src.length, 101);
    const scopedFile = path.join(testCase.cacheDir, 'dashboard-scope-v1.sqlite3');
    assert.equal(sqlite(scopedFile, 'SELECT scope FROM dashboard;').trim(), '101:0');
    assert.notDeepEqual(readFileSync(scopedFile), testCase.originalCache);
});

test('an incomplete search response cannot replace a same-account cached dashboard', t => {
    const testCase = scenario(t, {searchFails: false, incompletePage: 1});
    assert.deepEqual(testCase.run('cached').update.ids.prs.data.src.map(row => row.uid), [oldURL]);
    assert.deepEqual(testCase.run('first'), {});
    testCase.assertNoCacheWrites();
});

test('a cold dashboard offers only matching recent picker rows before searching', t => {
    const recent = {...oldItem, updatedAt: new Date().toISOString()};
    const older = {...oldItem, uid: fetchedItem.url, arg: fetchedItem.url, updatedAt: '2000-01-01T00:00:00Z'};
    const testCase = scenario(t, {mode: 'picker', days: '7', cachedRows: [recent, older]});
    const staleAuth = scenario(t, {mode: 'picker', days: '7', cachedRows: [recent], cacheToken: 'token-b'});
    assert.deepEqual(testCase.runDashboard('cached').update.ids.prs.data.src.map(row => row.uid), [oldURL]);
    assert.equal(staleAuth.runDashboard('cached').update.ids.prs, undefined);
    assert.equal(testCase.searchCount(), 0);
    const failed = testCase.runDashboard('first').update.ids;
    assert.deepEqual(failed.prs.data.src.map(row => row.uid), [oldURL]);
    assert.equal(failed.prs.data.src[0].previewState, 'unavailable');
    assert.match(failed.loadstatus.text, /^Could not load GitHub /);
    testCase.assertNoCacheWrites();
});

test('picker displays matching stale rows before searching and replaces them on its one rerun', t => {
    const testCase = scenario(t, {mode: 'picker', searchFails: false});
    const first = testCase.run();
    assert.deepEqual(first.items.map(item => item.uid), [oldURL]);
    assert.equal(testCase.searchCount(), 0);
    assert.equal(first.rerun, 0.1);
    assert.equal(first.cache, undefined);

    const refreshed = testCase.run(first.variables);
    assert.deepEqual(refreshed.items.map(item => item.uid), [fetchedItem.url]);
    assert.equal(refreshed.rerun, undefined);
    assert.equal(testCase.searchCount(), 2);
    assert.deepEqual(testCase.run(), refreshed);
    assert.equal(testCase.searchCount(), 2);
});

test('picker returns the latest ten unique rows and preserves all participation reasons', t => {
    const results = Array.from({length: 12}, (_, i) => {
        const number = 400 + i;
        return {...fetchedItem, number, url: `https://github.com/owner/repo/pull/${number}`,
            updatedAt: `2026-01-${String(20 - i).padStart(2, '0')}T12:00:00Z`};
    });
    const testCase = scenario(t, {mode: 'picker', age: staleLimit, searchFails: false, results});
    const output = testCase.run();
    assert.deepEqual(output.items.map(row => row.uid), results.slice(0, 10).map(row => row.url));
    assert.ok(output.items.every(row => row.subtitle.endsWith('Authored · Review requested')));
    assert.equal(testCase.searchCount(), 2);
    assert.equal(sqlite(testCase.cacheFile, 'SELECT count(*) FROM bodies;').trim(), '0');
});

test('picker refreshes a same-account snapshot at the freshness threshold', t => {
    const testCase = scenario(t, {mode: 'picker', age: freshLimit});
    const cached = testCase.run();
    assert.deepEqual(cached.items.map(item => item.uid), [oldURL]);
    assert.equal(cached.rerun, 0.1);
    assert.equal(testCase.searchCount(), 0);
});

test('picker retains a matching stale list on fetch failure without scheduling another rerun', t => {
    const testCase = scenario(t, {mode: 'picker'});
    const first = testCase.run();
    const failed = testCase.run(first.variables);
    assert.deepEqual(failed.items, first.items);
    assert.equal(failed.rerun, undefined);
    assert.ok(testCase.searchCount() > 0);
    testCase.assertNoCacheWrites();
});

test('picker does not show stale rows after expiration or a credential change', async t => {
    for (const [name, options] of [
        ['expired', {age: staleLimit}],
        ['other identity before launch', {activeToken: 'token-b'}],
        ['identity changed during refresh', {authAfterSearch: 'token-b', searchFails: false}]
    ]) {
        await t.test(name, t => {
            const testCase = scenario(t, {mode: 'picker', ...options});
            const first = testCase.run();
            const output = options.authAfterSearch ? testCase.run(first.variables) : first;
            assert.equal(output.rerun, undefined);
            assert.equal(output.items.length, 1);
            assert.equal(output.items[0].valid, false);
            assert.match(output.items[0].title, /^Could not load GitHub /);
            assert.ok(testCase.searchCount() > 0);
            testCase.assertNoCacheWrites();
        });
    }
});

test('picker narrows the dashboard list before taking the latest ten', t => {
    const row = (index, repository) => {
        const url = `https://github.com/example-org/${repository}/pull/${index}`;
        return {...oldItem, uid: url, arg: url, match: `Fix résumé controls example-org/${repository} #${index}`};
    };
    const matches = Array.from({length: 12}, (_, index) => row(30 - index, 'widget-builder'));
    const unrelated = Array.from({length: 12}, (_, index) => row(50 - index, 'another-repo'));
    const testCase = scenario(t, {age: 0, cachedRows: [...unrelated, ...matches]});
    const output = testCase.runPicker('WARN'); // No match must not trigger a refresh of a fresh list.
    assert.equal(output.items[0].valid, false);
    assert.deepEqual(testCase.runPicker('Widget resume').items.map(item => item.uid),
        matches.slice(0, 10).map(item => item.uid));
    assert.deepEqual(testCase.runPicker('re\u0301sume\u0301').items.map(item => item.uid),
        [...unrelated, ...matches].slice(0, 10).map(item => item.uid));
    assert.equal(testCase.runPicker('rêsumé').items[0].valid, false);
    assert.equal(testCase.runPicker('widget.*').items[0].valid, false);
    assert.equal(testCase.searchCount(), 0);
});

test('filtered picker refreshes the broad snapshot without using another credential’s rows', t => {
    const testCase = scenario(t, {activeToken: 'token-b', searchFails: false});
    const waiting = testCase.runPicker('New');
    assert.equal(waiting.items[0].valid, false);
    assert.equal(testCase.searchCount(), 0);
    const found = testCase.runPicker('New', waiting.variables);
    assert.deepEqual(found.items.map(item => item.uid), [fetchedItem.url]);
    assert.equal(testCase.searchCount(), 2);
    const loaded = testCase.run('cached').update.ids.prs.data.src;
    assert.deepEqual(loaded.map(row => row.uid), [fetchedItem.url]);
    assert.equal(testCase.searchCount(), 2);
});

test('filtered picker finds a match on page two without repeating any search page', t => {
    const pageOne = Array.from({length: 100}, (_, i) => ({
        ...fetchedItem, title: 'Unrelated queue entry', number: 200 + i,
        url: `https://github.com/owner/repo/pull/${200 + i}`
    }));
    const testCase = scenario(t, {
        activeToken: 'token-b', searchFails: false, limit: '1', days: '1', pages: [pageOne, [fetchedItem]]
    });
    const waiting = testCase.runPicker('new fetched');
    const found = testCase.runPicker('new fetched', waiting.variables);
    assert.deepEqual(found.items.map(row => row.uid), [fetchedItem.url]);
    const calls = readFileSync(testCase.searchLog, 'utf8').trim().split('\n');
    assert.equal(calls.length, 4);
    assert.equal(calls.filter(line => /\bpage=1\b/.test(line)).length, 2);
    assert.equal(calls.filter(line => /\bpage=2\b/.test(line)).length, 2);
    assert.ok(calls.every(line => !line.includes('updated:>=') && line.includes('per_page=100')));
});
