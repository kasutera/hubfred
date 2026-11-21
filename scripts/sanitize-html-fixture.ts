import { sanitizeHtml } from './sanitize-html';

const itemURL = 'https://github.com/acme/project/issues/42';

function assertContains(value: string, expected: string, label: string): void {
    if (!value.includes(expected)) throw new Error(`${label}: missing ${expected}`);
}

function assertAbsent(value: string, unexpected: string, label: string): void {
    if (value.includes(unexpected)) throw new Error(`${label}: unexpected ${unexpected}`);
}

export function run(_argv: string[]): string {
    const allowed = sanitizeHtml(
        '<p><strong>Bold</strong> <em>italic</em> <a href="https://github.com/acme/project/issues/7">issue</a></p>',
        itemURL
    );
    assertContains(allowed, '<strong>Bold</strong>', 'allowed elements');
    assertContains(allowed, '<em>italic</em>', 'allowed elements');
    assertContains(allowed, 'href="https://github.com/acme/project/issues/7"', 'allowed link');

    const allowedAttributes = sanitizeHtml(
        '<div class="warning">note</div><table><tbody><tr><td align="center">cell</td></tr></tbody></table>',
        itemURL
    );
    assertContains(allowedAttributes, 'class="warning"', 'allowed alert class');
    assertContains(allowedAttributes, 'align="center"', 'allowed table alignment');

    const ordinaryMarkup = sanitizeHtml('<span class="custom">ordinary text</span>', itemURL);
    assertContains(ordinaryMarkup, 'ordinary text', 'unknown element contents');
    assertAbsent(ordinaryMarkup, '<span', 'unknown element');

    const attributes = sanitizeHtml(
        '<p id="ignored" title="ignored">paragraph</p><ol start="3" onclick="ignored"><li>item</li></ol>',
        itemURL
    );
    assertContains(attributes, '<ol start="3">', 'allowed list attribute');
    assertAbsent(attributes, 'id="', 'disallowed id attribute');
    assertAbsent(attributes, 'title="', 'disallowed title attribute');
    assertAbsent(attributes, 'onclick=', 'disallowed event attribute');

    const links = sanitizeHtml(
        '<p><a href="/acme/project/issues/7">relative</a> <a href="mailto:reader@example.com">mail</a> <a href="ftp://files.example.com/readme">other scheme</a></p>',
        itemURL
    );
    assertContains(links, 'href="https://github.com/acme/project/issues/7"', 'relative web link');
    assertContains(links, 'mail', 'mail link label');
    assertContains(links, 'other scheme', 'other-scheme link label');
    assertAbsent(links, 'mailto:', 'mail link');
    assertAbsent(links, 'ftp:', 'other-scheme link');

    return 'Foundation sanitizer tests passed';
}
