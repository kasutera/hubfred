'use strict';

const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');
const { spawnSync } = require('node:child_process');
const { mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, utimesSync, writeFileSync } = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { test } = require('node:test');

const root = path.resolve(__dirname, '..');
const loader = path.join(root, 'workflow', 'prs.alfredui', 'load.sh');
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
    body: 'New fetched preview'
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

function scenario(t, {
    activeToken = 'token-a', cacheToken = 'token-a',
    searchFails = true, authAfterSearch = null
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

    const cacheFile = path.join(cacheDir, 'dashboard-v2.json');
    writeFileSync(cacheFile, JSON.stringify({key: cacheKey(cacheToken), results: {items: [oldItem]}}));
    const cachedAt = Math.floor(Date.now() / 1000) - 120;
    utimesSync(cacheFile, cachedAt, cachedAt);
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

    function run() {
        const result = spawnSync('/bin/bash', [loader], {
            cwd: path.dirname(loader),
            env,
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
            assert.deepEqual(readdirSync(cacheDir).sort(), ['dashboard-v2.json', 'octicons-v5']);
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

test('unchanged auth emits and caches the same successful search results', t => {
    const testCase = scenario(t, {searchFails: false});
    const output = testCase.run();
    const rows = output.update.ids.prs.data.src;
    assert.equal(rows.length, 1);
    assert.equal(rows[0]['title.text'], fetchedItem.title);
    assert.equal(rows[0].uid, fetchedItem.url);
    assert.equal(testCase.currentToken(), 'token-a');
    assert.equal(testCase.searchCount(), 2);

    const persisted = JSON.parse(readFileSync(testCase.cacheFile, 'utf8'));
    assert.equal(persisted.key, cacheKey('token-a'));
    assert.equal(persisted.results.items.length, 1);
    assert.equal(persisted.results.items[0].title, fetchedItem.title);
});
