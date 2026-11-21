'use strict';

const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const path = require('node:path');
const { test } = require('node:test');

const root = path.resolve(__dirname, '..');
const renderer = process.env.HUBFRED_TEST_RENDERER_PATH ||
    path.join(root, 'workflow', 'prs.alfredui', 'render-markdown.js');
const marked = process.env.HUBFRED_TEST_MARKED_PATH ||
    path.join(root, 'node_modules', 'marked', 'lib', 'marked.umd.js');
const itemURL = 'https://github.com/owner/repo/issues/42';

function render(markdown) {
    return spawnSync('/usr/bin/osascript', [
        '-l', 'JavaScript', renderer, marked, itemURL
    ], {
        input: markdown,
        encoding: 'utf8',
        timeout: 15_000,
        maxBuffer: 2 * 1024 * 1024
    });
}

function expectRendererError(markdown, message) {
    const result = render(markdown);
    assert.notEqual(result.status, 0, result.stdout);
    assert.match(`${result.stdout}\n${result.stderr}`, new RegExp(message));
}

function table(columns, rows = 0) {
    const header = Array.from({length: columns}, (_, index) => `heading ${index}`);
    const delimiter = Array(columns).fill('---');
    const body = Array.from({length: rows}, () => `| ${Array(columns).fill('cell').join(' | ')} |`);
    return [`| ${header.join(' | ')} |`, `| ${delimiter.join(' | ')} |`, ...body].join('\n');
}

test('uses the production JXA renderer for GitHub task checklists', () => {
    const result = render('- [x] completed\n- [ ] remaining');
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /<input type="checkbox" disabled checked>/);
    assert.match(result.stdout, /<input type="checkbox" disabled>/);
});

test('resolves ordinary relative links and omits unsupported link types', () => {
    const result = render('[discussion](#details)\n\n[contact](mailto:reader@example.com)');
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /href="https:\/\/github\.com\/owner\/repo\/issues\/42#details"/);
    assert.match(result.stdout, />contact\s*</);
    assert.doesNotMatch(result.stdout, /mailto:/);
});

test('removes ordinary raw markup outside the supported Markdown vocabulary', () => {
    const result = render('<article>ordinary text</article>');
    assert.equal(result.status, 0, result.stderr);
    assert.doesNotMatch(result.stdout, /<article|ordinary text/);
});

test('counts UTF-8 bytes at the 128 KiB Markdown input limit', () => {
    const atLimit = render('é'.repeat(64 * 1024));
    assert.equal(atLimit.status, 0, atLimit.stderr);
    expectRendererError('é'.repeat(64 * 1024 + 1), 'Markdown input too large');
});

test('accepts HTML output at 512 KiB and rejects output above the limit', () => {
    const atLimit = render('&'.repeat(104_856));
    assert.equal(atLimit.status, 0, atLimit.stderr);
    expectRendererError('&'.repeat(110_000), 'Markdown output too large');
});

test('accepts 128-column tables and rejects wider tables', () => {
    const result = render(table(128));
    assert.equal(result.status, 0, result.stderr);
    assert.equal((result.stdout.match(/<th>/g) || []).length, 128);
    expectRendererError(table(129), 'Markdown table has too many columns');
});

test('counts table headers and cells across the document up to 8192', () => {
    const atLimit = render(table(64, 127));
    assert.equal(atLimit.status, 0, atLimit.stderr);
    assert.equal((atLimit.stdout.match(/<(?:th|td)>/g) || []).length, 8192);
    expectRendererError(`${table(64, 127)}\n\n${table(1)}`, 'Markdown table has too many cells');
});
