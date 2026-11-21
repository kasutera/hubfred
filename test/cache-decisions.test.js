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

test('refresh suppression uses a strict 30-second age and the matching identity', () => {
    assert.equal(decision('cache_should_skip_fetch', 29, 'identity-a', 'identity-a'), 0);
    assert.equal(decision('cache_should_skip_fetch', 30, 'identity-a', 'identity-a'), 1);
    assert.equal(decision('cache_should_skip_fetch', 29, 'identity-a', 'identity-b'), 1);
});

test('cached rows are reusable only below 600 seconds for the same identity', () => {
    assert.equal(decision('cache_should_show_cached', 599, 'identity-a', 'identity-a'), 0);
    assert.equal(decision('cache_should_show_cached', 600, 'identity-a', 'identity-a'), 1);
    assert.equal(decision('cache_should_show_cached', 599, 'identity-a', 'identity-b'), 1);
});

test('failed refresh fallback requires a matching identity and an actual search failure', () => {
    assert.equal(decision('cache_should_reuse_after_failure', 599, 'identity-a', 'identity-a', true), 0);
    assert.equal(decision('cache_should_reuse_after_failure', 600, 'identity-a', 'identity-a', true), 1);
    assert.equal(decision('cache_should_reuse_after_failure', 599, 'identity-a', 'identity-a', false), 1);
    assert.equal(decision('cache_should_reuse_after_failure', 599, 'identity-a', 'identity-b', true), 1);
});
