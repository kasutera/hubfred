ObjC.import('Foundation');

const attachment = /^(?:https:\/\/github\.com)?\/user-attachments\/assets\/[0-9a-f-]+$/i;

function escapeHtml(value) {
    return value.replace(/[&<>"']/g, character => ({
        '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
    })[character]);
}

function safeHref(href) {
    return !/[\x00-\x20\x7f\\]/.test(href) &&
        (!/^[^/?#]*:/.test(href) || /^https?:\/\//i.test(href));
}

function anchor(href, label) {
    return safeHref(href) ? `<a href="${escapeHtml(href)}">${label}</a>` : label;
}

function attachmentLink(href) {
    return anchor(href.startsWith('/') ? `https://github.com${href}` : href,
        'Open attachment in browser');
}

// Accept only a standalone img tag for GitHub attachments. Rebuild the link
// instead of copying attributes or allowing any raw HTML into WebKit.
function rawAttachment(tag) {
    const match = /^\s*<img\s+((?:[^"'<>]|"[^"]*"|'[^']*')*)>\s*$/i.exec(tag);
    if (!match) return '';
    const attributes = /([^\s=/'"<>]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/g;
    let attribute;
    while ((attribute = attributes.exec(match[1])) !== null) {
        if (attribute[1].toLowerCase() !== 'src') continue;
        const href = attribute[2] ?? attribute[3] ?? attribute[4] ?? '';
        return attachment.test(href) ? attachmentLink(href) : '';
    }
    return '';
}

function run([libraryPath]) {
    const library = ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(
        libraryPath, $.NSUTF8StringEncoding, null));
    const module = {exports: {}};
    new Function('module', 'exports', library)(module, module.exports);
    const input = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
    const markdown = ObjC.unwrap($.NSString.alloc.initWithDataEncoding(input, $.NSUTF8StringEncoding));
    let insideLink = false;
    const parser = new module.exports.Marked({gfm: true, renderer: {
        html({text}) { return insideLink ? '' : rawAttachment(text); },
        image({href, text}) {
            const label = escapeHtml(text || 'Open image in browser');
            if (insideLink) return label;
            return attachment.test(href) ? attachmentLink(href) : anchor(href, label);
        },
        link({href, tokens}) {
            insideLink = true;
            try {
                return anchor(href, this.parser.parseInline(tokens));
            } finally {
                insideLink = false;
            }
        },
        blockquote({tokens}) {
            const html = this.parser.parse(tokens);
            const alert = /^<p>\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\](?:\r?\n|<\/p>\s*|$)/.exec(html);
            if (!alert) return `<blockquote>\n${html}</blockquote>\n`;
            const kind = alert[1].toLowerCase();
            const label = kind[0].toUpperCase() + kind.slice(1);
            const contents = html.slice(alert[0].length);
            const start = alert[0].includes('</p>') ? '' : '<p>';
            return `<div class="${kind}"><p><strong>${label}</strong></p>${start}${contents}</div>\n`;
        }
    }});
    return parser.parse(markdown);
}
