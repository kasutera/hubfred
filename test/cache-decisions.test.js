'use strict';

const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const path = require('node:path');
const { test } = require('node:test');

const root = path.resolve(__dirname, '..');
const decisions = path.join(root, 'workflow', 'prs.alfredui', 'cache-decisions.sh');

function decision(name, ...args) {
    const result = spawnSync('/bin/bash', [
        '-c',
        'source "$1"; shift; decision=$1; shift; "$decision" "$@"',
        'cache-decision-test',
        decisions,
        name,
        ...args.map(String)
    ], {encoding: 'utf8'});
    assert.equal(result.error, undefined, result.error?.message);
    return result.status;
}

test('refresh is skipped only below the freshness threshold for the same identity', () => {
    assert.equal(decision('cache_should_skip_fetch', 'CACHE_FRESH_SECONDS - 1', 'identity-a', 'identity-a'), 0);
    assert.equal(decision('cache_should_skip_fetch', 'CACHE_FRESH_SECONDS', 'identity-a', 'identity-a'), 1);
    assert.equal(decision('cache_should_skip_fetch', 'CACHE_FRESH_SECONDS - 1', 'identity-a', 'identity-b'), 1);
});

test('cached rows are reusable only below the stale limit for the same identity', () => {
    assert.equal(decision('cache_should_show_cached', 'CACHE_STALE_SECONDS - 1', 'identity-a', 'identity-a'), 0);
    assert.equal(decision('cache_should_show_cached', 'CACHE_STALE_SECONDS', 'identity-a', 'identity-a'), 1);
    assert.equal(decision('cache_should_show_cached', 'CACHE_STALE_SECONDS - 1', 'identity-a', 'identity-b'), 1);
});

test('failed refresh fallback requires a matching identity and an actual search failure', () => {
    assert.equal(decision('cache_should_reuse_after_failure', 'CACHE_STALE_SECONDS - 1', 'identity-a', 'identity-a', true), 0);
    assert.equal(decision('cache_should_reuse_after_failure', 'CACHE_STALE_SECONDS', 'identity-a', 'identity-a', true), 1);
    assert.equal(decision('cache_should_reuse_after_failure', 'CACHE_STALE_SECONDS - 1', 'identity-a', 'identity-a', false), 1);
    assert.equal(decision('cache_should_reuse_after_failure', 'CACHE_STALE_SECONDS - 1', 'identity-a', 'identity-b', true), 1);
});
