'use strict';

const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');
const { execFileSync, spawnSync } = require('node:child_process');
const { mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { test } = require('node:test');

const root = path.resolve(__dirname, '..');
const loader = path.join(root, 'workflow', 'prs.alfredui', 'load.sh');
const picker = path.join(root, 'workflow', 'search.sh');
const [freshLimit, staleLimit] = execFileSync('/bin/bash', [
    '-ec', 'source "$1"; printf "%s %s" "$CACHE_FRESH_SECONDS" "$CACHE_STALE_SECONDS"',
    'cache-limits', path.join(path.dirname(loader), 'cache-decisions.sh')
], {encoding: 'utf8'}).split(' ').map(Number);
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
const mockGh = `
gh() {
    if [[ "$1" == auth && "$2" == token ]]; then
        /bin/cat "$HUBFRED_TEST_CURRENT_TOKEN_FILE"
        return 0
    fi
    if [[ "$1" == search ]]; then
        echo "$*" >> "$HUBFRED_TEST_SEARCH_LOG"
        [[ "\${HUBFRED_TEST_SEARCH_FAIL:-false}" != true ]] || return 1
        next_token=$(/usr/bin/jq -r '.afterSearchAuth // empty' "$HUBFRED_TEST_SEARCH_RESULTS")
        /usr/bin/jq -c '.results' "$HUBFRED_TEST_SEARCH_RESULTS"
        if [[ -n "$next_token" ]]; then
            printf '%s' "$next_token" > "$HUBFRED_TEST_CURRENT_TOKEN_FILE"
        fi
        return 0
    fi
    return 1
}
export -f gh
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
    age = Math.floor((freshLimit + staleLimit) / 2)
} = {}) {
    const directory = mkdtempSync(path.join(os.tmpdir(), 'hubfred-load-'));
    t.after(() => rmSync(directory, {recursive: true, force: true}));
    const cacheDir = path.join(directory, 'cache');
    const iconDir = path.join(cacheDir, 'octicons-v5');
    mkdirSync(iconDir, {recursive: true});
    for (const color of ['AC6B49', '4269A5', 'A48332', 'B15F91', '4E94B8', '62636D']) {
        for (const state of ['ready', 'draft']) {
            writeFileSync(path.join(iconDir, `${color}-${state}.png`), 'fixture');
        }
    }

    const cacheName = mode === 'picker' ? 'pr-picker-v1.sqlite3' : 'dashboard-v3.sqlite3';
    const cacheFile = path.join(cacheDir, cacheName);
    const {body, ...oldRow} = oldItem;
    const literal = value => `'${value.replaceAll("'", "''")}'`;
    sqlite(cacheFile, `
        CREATE TABLE ${mode} (identity TEXT NOT NULL, saved_at INTEGER NOT NULL, digest TEXT NOT NULL, list TEXT NOT NULL);
        CREATE TABLE bodies (url TEXT PRIMARY KEY, body TEXT NOT NULL) WITHOUT ROWID;
        INSERT INTO ${mode} VALUES (${literal(cacheKey(cacheToken))}, unixepoch() - ${age}, 'old-result-digest',
            ${literal(JSON.stringify({items: [oldRow]}))});
        INSERT INTO bodies VALUES (${literal(oldURL)}, ${literal(JSON.stringify(body))});
    `);
    const originalCache = readFileSync(cacheFile);
    const originalCacheStats = statSync(cacheFile);
    const searchResults = path.join(directory, 'search-results.json');
    writeFileSync(searchResults, JSON.stringify({
        results: [fetchedItem],
        ...(authAfterSearch === null ? {} : {afterSearchAuth: authAfterSearch})
    }));
    const tokenFile = path.join(directory, 'current-token');
    writeFileSync(tokenFile, activeToken);
    const envFile = path.join(directory, 'bash-env');
    writeFileSync(envFile, mockGh);
    const searchLog = path.join(directory, 'search.log');
    const env = {
        ...process.env,
        BASH_ENV: envFile,
        HOME: directory,
        alfred_workflow_cache: cacheDir,
        dashboard_kind: 'prs',
        HUBFRED_TEST_CURRENT_TOKEN_FILE: tokenFile,
        HUBFRED_TEST_SEARCH_FAIL: String(searchFails),
        HUBFRED_TEST_SEARCH_LOG: searchLog,
        HUBFRED_TEST_SEARCH_RESULTS: searchResults
    };
    delete env.GH_TOKEN;
    delete env.GITHUB_TOKEN;
    delete env.hubfred_refresh_identity;

    function run(...args) {
        const script = mode === 'picker' ? picker : loader;
        const command = mode === 'picker' ? [script, 'cached-picker', 'prs'] : [script, ...args];
        const result = spawnSync('/bin/bash', command, {
            cwd: path.dirname(script),
            env: mode === 'picker' ? {...env, ...args[0]} : env,
            encoding: 'utf8',
            maxBuffer: 2 * 1024 * 1024
        });
        assert.equal(result.status, 0, result.stderr);
        return JSON.parse(result.stdout);
    }

    return {
        cacheDir,
        cacheFile,
        originalCache,
        originalCacheStats,
        run,
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
    assert.equal(testCase.searchCount(), 2);
    testCase.assertNoCacheWrites();
});

test('does not show older cached data after switching to another auth identity', t => {
    const testCase = scenario(t, {activeToken: 'token-b', cacheToken: 'token-a'});
    assert.equal(testCase.run('cached').update.ids.prs, undefined);
    assertRefreshFailure(testCase.run());
    assert.equal(testCase.searchCount(), 2);
    testCase.assertNoCacheWrites();
});

test('search fixture auth change suppresses fetched results and cache writes and clears preview', t => {
    const testCase = scenario(t, {searchFails: false, authAfterSearch: 'token-b'});
    assertRefreshFailure(testCase.run());
    assert.equal(testCase.currentToken(), 'token-b');
    assert.equal(testCase.searchCount(), 2);
    testCase.assertNoCacheWrites();
});

test('a successful refresh serves the same rows from the body-free cache', t => {
    const testCase = scenario(t, {searchFails: false});
    const output = testCase.run();
    const rows = output.update.ids.prs.data.src;
    assert.equal(rows.length, 1);
    assert.equal(rows[0]['title.text'], fetchedItem.title);
    assert.equal(rows[0].uid, fetchedItem.url);
    assert.equal(testCase.currentToken(), 'token-a');
    assert.equal(testCase.searchCount(), 2);

    assert.deepEqual(testCase.run('cached').update.ids.prs.data.src, rows);
    assert.deepEqual(testCase.run('refresh'), {});
    assert.equal(testCase.searchCount(), 2);
    const persistedList = JSON.parse(sqlite(testCase.cacheFile, 'SELECT list FROM dashboard;'));
    assert.equal(persistedList.items[0].body, undefined);
    const persistedBody = JSON.parse(sqlite(testCase.cacheFile, 'SELECT body FROM bodies;'));
    assert.equal(persistedBody, fetchedItem.body);
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

test('picker retains a matching stale list on fetch failure without scheduling another rerun', t => {
    const testCase = scenario(t, {mode: 'picker'});
    const first = testCase.run();
    const failed = testCase.run(first.variables);
    assert.deepEqual(failed.items, first.items);
    assert.equal(failed.rerun, undefined);
    assert.equal(testCase.searchCount(), 2);
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
            assert.equal(testCase.searchCount(), 2);
            testCase.assertNoCacheWrites();
        });
    }
});
