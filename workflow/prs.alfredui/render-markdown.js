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

const MAX_MARKDOWN_BYTES = 128 * 1024;
const MAX_TABLE_COLUMNS = 128;
const MAX_TABLE_CELLS = 8192;
const MAX_HTML_BYTES = 512 * 1024;

function readMarkdown() {
    const handle = $.NSFileHandle.fileHandleWithStandardInput;
    const input = $.NSMutableData.alloc.init;
    let length = 0;
    while (true) {
        const chunk = handle.readDataOfLength(Math.min(8192, MAX_MARKDOWN_BYTES - length + 1));
        const chunkLength = Number(chunk.length);
        if (chunkLength === 0) break;
        if (chunkLength > MAX_MARKDOWN_BYTES - length) throw new Error(inputError);
        input.appendData(chunk);
        length += chunkLength;
    }
    const markdown = $.NSString.alloc.initWithDataEncoding(input, $.NSUTF8StringEncoding);
    if (!markdown) throw new Error('Markdown input is not valid UTF-8');
    return ObjC.unwrap(markdown);
}

// Match Marked's splitCells() pipe escaping when counting header columns.
function countCells(row) {
    let count = 1;
    let firstPipe = -1;
    let lastPipe = -1;
    let backslashes = 0;
    for (let i = 0; i < row.length; i++) {
        if (row[i] === '|') {
            if (backslashes % 2 === 0) {
                if (firstPipe < 0) firstPipe = i;
                lastPipe = i;
                count++;
            }
            backslashes = 0;
        } else if (row[i] === '\\') {
            backslashes++;
        } else {
            backslashes = 0;
        }
    }
    if (firstPipe < 0) return row.trim() ? count : 0;
    if (!row.slice(0, firstPipe).trim()) count--;
    if (!row.slice(lastPipe + 1).trim()) count--;
    return count;
}

function checkTableLimits(tokenizer, source, state) {
    const match = tokenizer.rules.block.table.exec(source);
    if (!match || !tokenizer.rules.other.tableDelimiter.test(match[2])) return;
    const columns = countCells(match[1]);
    const alignments = match[2].replace(tokenizer.rules.other.tableAlignChars, '').split('|').length;
    if (columns !== alignments) return;
    if (columns > MAX_TABLE_COLUMNS) throw new Error('Markdown table has too many columns');
    const rows = match[3]?.trim()
        ? match[3].replace(tokenizer.rules.other.tableRowBlankLine, '').split('\n').length
        : 0;
    state.cells += columns * (rows + 1);
    if (state.cells > MAX_TABLE_CELLS) throw new Error('Markdown table has too many cells');
}

const inputError = 'Markdown input too large';
const outputError = 'Markdown output too large';

function run([libraryPath]) {
    const library = ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(
        libraryPath, $.NSUTF8StringEncoding, null));
    const module = {exports: {}};
    new Function('module', 'exports', library)(module, module.exports);
    const markdown = readMarkdown();
    const state = {cells: 0};
    const tokenizer = new module.exports.Tokenizer();
    const originalTable = tokenizer.table;
    tokenizer.table = function(source) {
        checkTableLimits(this, source, state);
        return originalTable.call(this, source);
    };
    let insideLink = false;
    const parser = new module.exports.Marked({gfm: true, tokenizer, renderer: {
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
    const html = parser.parse(markdown);
    const htmlBytes = $.NSString.stringWithString(html).lengthOfBytesUsingEncoding($.NSUTF8StringEncoding);
    if (htmlBytes > MAX_HTML_BYTES) throw new Error(outputError);
    const sanitized = sanitizeHtml(html, itemURL);
    const sanitizedBytes = $.NSString.stringWithString(sanitized).lengthOfBytesUsingEncoding($.NSUTF8StringEncoding);
    if (sanitizedBytes > MAX_HTML_BYTES) throw new Error(outputError);
    return sanitized;
}
