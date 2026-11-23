'use strict';

const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const { chmodSync, mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { test } = require('node:test');

const root = path.resolve(__dirname, '..');
const core = path.join(root, 'workflow', 'search-core.sh');
const workflow = path.join(root, 'workflow');
const categories = [
    ['prs:author', 'is:pr is:open author:login'],
    ['prs:user-review-requested', 'is:pr is:open user-review-requested:login'],
    ['issues:assignee', 'is:issue is:open assignee:login'],
    ['issues:author', 'is:issue is:open author:login'],
    ['issues:mentions', 'is:issue is:open mentions:login'],
    ['issues:commenter', 'is:issue is:open commenter:login']
];

const mockGh = String.raw`#!/bin/bash
set -u
if [ "$1" = api ] && [ "$2" = user ]; then
    printf 'login\n'
    exit 0
fi
query=
for arg in "$@"; do
    case "$arg" in
        q=*) query=$(printf '%s' "$arg" | cut -c3-) ;;
    esac
done
case "$query" in
    *assignee:login*)
        printf '%s\n' "$$" > "$CONTROL/slow.pid"
        : > "$CONTROL/slow.started"
        exec /bin/sleep 30
        ;;
    "is:pr "*author:login*)
        attempt=0
        while [ "$attempt" -lt 300 ]; do
            if [ -e "$CONTROL/slow.started" ]; then
                if [ "$PHASE" = first ] && [ -s "$CONTROL/session/category-1.json" ]; then break; fi
                if [ "$PHASE" = more ] && /usr/bin/jq -e '.loaded == 2' "$CONTROL/session/category-1.json" >/dev/null 2>&1; then break; fi
            fi
            /bin/sleep 0.01
            attempt=$((attempt + 1))
        done
        if [ "$attempt" -ge 300 ]; then
            : > "$CONTROL/synchronization-failed"
            exit 88
        fi
        : > "$CONTROL/failure-synchronized"
        printf 'HTTP/1.1 500 Server Error\r\nContent-Type: application/json\r\n\r\n{"message":"synthetic failure"}\n'
        exit 1
        ;;
esac
if [ "$PHASE" = first ]; then
    response='{"items":[],"total_count":0,"incomplete_results":false}'
else
    response='{"items":[{"id":17}],"total_count":2,"incomplete_results":false}'
fi
printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n%s\n' "$response"
`;

const searchScript = String.raw`if [ "$ERREXIT" = 1 ]; then
    set -euo pipefail
else
    set -uo pipefail
fi
source "$CORE"
kind=all
workflow_dir="$WORKFLOW"
cache_dir="$CONTROL/cache"
session="$CONTROL/session"
token=synthetic
gh_path="$CONTROL/gh"
if [ "$PHASE" = first ]; then
    search_first 10
else
    search_more 10
fi
`;

function runFailureScenario(phase, errexit) {
    const scratch = mkdtempSync(path.join(os.tmpdir(), 'hubfred-search-cancel-'));
    const control = scratch;
    const session = path.join(control, 'session');
    mkdirSync(session);
    mkdirSync(path.join(control, 'cache'));
    const gh = path.join(control, 'gh');
    writeFileSync(gh, mockGh);
    chmodSync(gh, 0o700);

    if (phase === 'more') {
        categories.forEach(([category, query], index) => {
            writeFileSync(path.join(session, `category-${index}.json`), JSON.stringify({
                kind: 'all', category, query, perPage: 1, loaded: 1, totalCount: 2, nextPage: 2,
                items: [{id: index}]
            }));
        });
    }

    try {
        const result = spawnSync('/bin/bash', ['-c', searchScript], {
            encoding: 'utf8',
            env: {
                ...process.env,
                CONTROL: control,
                CORE: core,
                WORKFLOW: workflow,
                PHASE: phase,
                ERREXIT: errexit ? '1' : '0'
            },
            timeout: 8000
        });
        assert.ifError(result.error);
        assert.notEqual(result.status, 0, `expected ${phase} search to fail; stderr: ${result.stderr}`);
        assert.equal(result.signal, null);
        assert.equal(readdirSync(session).some(name => name.startsWith('.search-worker.')), false);
        assert.equal(exists(path.join(control, 'failure-synchronized')), true);
        assert.equal(exists(path.join(control, 'synchronization-failed')), false);

        const slowPid = Number(readFileSync(path.join(control, 'slow.pid'), 'utf8').trim());
        assert.ok(Number.isInteger(slowPid) && slowPid > 0);
        assert.throws(() => process.kill(slowPid, 0), {code: 'ESRCH'});

        const successfulReceipt = JSON.parse(readFileSync(path.join(session, 'category-1.json'), 'utf8'));
        assert.equal(successfulReceipt.category, categories[1][0]);
        if (phase === 'first') {
            assert.equal(successfulReceipt.loaded, 0);
            assert.equal(exists(path.join(session, 'category-0.json')), false);
        } else {
            assert.equal(successfulReceipt.loaded, 2);
            assert.equal(successfulReceipt.nextPage, 0);
            assert.equal(JSON.parse(readFileSync(path.join(session, 'category-0.json'), 'utf8')).loaded, 1);
        }
    } finally {
        rmSync(scratch, {recursive: true, force: true});
    }
}

function exists(file) {
    try {
        readFileSync(file);
        return true;
    } catch (error) {
        if (error.code === 'ENOENT') return false;
        throw error;
    }
}

test('first and more category failures stop active sibling GitHub requests', () => {
    for (const phase of ['first', 'more']) {
        for (const errexit of [true, false]) runFailureScenario(phase, errexit);
    }
});
