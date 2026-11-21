'use strict';

const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const { mkdtempSync, rmSync } = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { test } = require('node:test');
const { build } = require('esbuild');

const repositoryRoot = path.resolve(__dirname, '..');

test('sanitizes HTML directly with Foundation', {skip: process.platform !== 'darwin'}, async () => {
    const temporaryDirectory = mkdtempSync(path.join(os.tmpdir(), 'hubfred-sanitize-html-'));
    const testBundle = path.join(temporaryDirectory, 'sanitizer-test.js');

    try {
        await build({
            entryPoints: [path.join(repositoryRoot, 'scripts/sanitize-html-fixture.ts')],
            bundle: true,
            format: 'iife',
            globalName: 'sanitizeHtmlTest',
            target: 'es2019',
            banner: {js: 'function run(argv) { return sanitizeHtmlTest.run(argv); }'},
            outfile: testBundle
        });

        const output = execFileSync('/usr/bin/osascript', ['-l', 'JavaScript', testBundle], {
            cwd: repositoryRoot,
            encoding: 'utf8',
            timeout: 5000,
            maxBuffer: 1024 * 1024
        });
        assert.equal(output.trim(), 'Foundation sanitizer tests passed');
    } finally {
        rmSync(temporaryDirectory, {recursive: true, force: true});
    }
});
