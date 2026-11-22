'use strict';

const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const { mkdtempSync, rmSync, writeFileSync } = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { test } = require('node:test');

const root = path.resolve(__dirname, '..');
const formatter = path.join(root, 'workflow', 'search-results.jq');
const updatedAt = day => `2026-01-${String(day).padStart(2, '0')}T12:00:00Z`;

function item({number, repository, day, title = `Work item ${repository}#${number}`}) {
    return {
        author: {login: 'reader'},
        number,
        repository: {nameWithOwner: repository},
        title,
        updatedAt: updatedAt(day),
        url: `https://github.com/${repository}/pull/${number}`,
        isDraft: false
    };
}

test('merges by URL, keeps participation reasons, sorts by update time, and limits pickers to ten', t => {
    const directory = mkdtempSync(path.join(os.tmpdir(), 'hubfred-search-results-'));
    t.after(() => rmSync(directory, {recursive: true, force: true}));
    const fixtures = [
        {repository: 'owner/repo-a', number: 1, day: 5},
        {repository: 'owner/repo-b', number: 1, day: 12},
        {repository: 'owner/repo-a', number: 8, day: 2},
        {repository: 'owner/repo-b', number: 8, day: 9},
        {repository: 'owner/repo-a', number: 3, day: 7},
        {repository: 'owner/repo-b', number: 3, day: 1},
        {repository: 'owner/repo-a', number: 4, day: 11},
        {repository: 'owner/repo-b', number: 4, day: 4},
        {repository: 'owner/repo-a', number: 5, day: 10},
        {repository: 'example-org/widget-builder', number: 5, day: 3, title: 'Fix controls'},
        {repository: 'owner/repo-a', number: 6, day: 6},
        {repository: 'owner/repo-b', number: 6, day: 8}
    ];
    const authored = fixtures.map(item);
    const reviewed = [item({repository: 'owner/repo-b', number: 1, day: 12})];
    const firstFile = path.join(directory, 'authored.json');
    const secondFile = path.join(directory, 'reviewed.json');
    writeFileSync(firstFile, JSON.stringify(authored));
    writeFileSync(secondFile, JSON.stringify(reviewed));

    const result = spawnSync('/usr/bin/jq', [
        '-s',
        '--arg', 'icon_dir', directory,
        '--argjson', 'color_count', '6',
        '--argjson', 'search_limit', '10',
        '--arg', 'mode', 'picker',
        '--arg', 'noun', 'PRs',
        '--arg', 'reasons', 'Authored|Review requested',
        '-f', formatter,
        firstFile,
        secondFile
    ], {encoding: 'utf8'});

    assert.equal(result.status, 0, result.stderr);
    const output = JSON.parse(result.stdout);
    assert.equal(output.items.length, 10);
    assert.deepEqual(output.items.map(row => row.uid), [
        'https://github.com/owner/repo-b/pull/1',
        'https://github.com/owner/repo-a/pull/4',
        'https://github.com/owner/repo-a/pull/5',
        'https://github.com/owner/repo-b/pull/8',
        'https://github.com/owner/repo-b/pull/6',
        'https://github.com/owner/repo-a/pull/3',
        'https://github.com/owner/repo-a/pull/6',
        'https://github.com/owner/repo-a/pull/1',
        'https://github.com/owner/repo-b/pull/4',
        'https://github.com/example-org/widget-builder/pull/5'
    ]);
    assert.equal(new Set(output.items.map(row => row.uid)).size, 10);
    assert.equal(output.items.filter(row => row.uid.endsWith('/pull/1')).length, 2);
    assert.equal(output.items[0].title, 'Work item owner/repo-b#1');
    assert.ok(output.items[0].subtitle.endsWith('Authored · Review requested'));
    // Alfred's start-or-whitespace mode needs a word boundary before the repository name.
    assert.deepEqual(output.items.filter(row => /(?:^|\s)widget/i.test(row.match)).map(row => row.uid), [
        'https://github.com/example-org/widget-builder/pull/5'
    ]);
});
