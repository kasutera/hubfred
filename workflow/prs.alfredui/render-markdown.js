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
const HTML_PARSE_OPTIONS = $.NSXMLDocumentTidyHTML | $.NSXMLNodeLoadExternalEntitiesNever;
const ELEMENT_NODE_KIND = Number($.NSXMLElementKind);
const TEXT_NODE_KIND = Number($.NSXMLTextKind);
const allowedElements = new Set([
    'p', 'br', 'hr', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
    'strong', 'em', 'del', 'blockquote', 'ul', 'ol', 'li', 'pre', 'code',
    'table', 'thead', 'tbody', 'tr', 'th', 'td', 'div', 'input', 'a'
]);
const removedContentElements = new Set([
    'applet', 'base', 'canvas', 'embed', 'frame', 'frameset', 'head', 'iframe',
    'math', 'meta', 'noembed', 'noframes', 'noscript', 'object', 'plaintext',
    'script', 'style', 'svg', 'template', 'title', 'xmp'
]);
const alertClasses = new Set(['note', 'tip', 'important', 'warning', 'caution']);

function attribute(node, name) {
    const value = node.attributeForName(name);
    return value.isNil() ? null : ObjC.unwrap(value.stringValue);
}

function resolvedHref(href, baseURL) {
    if (baseURL === null || baseURL.isNil() || /[\x00-\x20\x7f\\]/.test(href)) return null;
    const url = $.NSURL.URLWithStringRelativeToURL($.NSString.stringWithString(href), baseURL);
    if (url.isNil()) return null;
    const absolute = url.absoluteURL;
    const scheme = ObjC.unwrap(absolute.scheme);
    const host = ObjC.unwrap(absolute.host);
    if (!scheme || !/^https?$/i.test(scheme) || !host) return null;
    return ObjC.unwrap(absolute.absoluteString);
}

function serializeChildren(node, baseURL, inListItem) {
    let result = '';
    for (let i = 0; i < Number(node.childCount); i++) {
        result += serializeNode(node.childAtIndex(i), baseURL, inListItem);
    }
    return result;
}

function serializeNode(node, baseURL, inListItem) {
    const kind = Number(node.kind);
    if (kind === TEXT_NODE_KIND) return escapeHtml(ObjC.unwrap(node.stringValue));
    if (kind !== ELEMENT_NODE_KIND) return '';

    const name = String(ObjC.unwrap(node.name)).toLowerCase();
    if (removedContentElements.has(name)) return '';
    const insideListItem = inListItem || name === 'li';
    if (name === 'input') {
        if (!inListItem || (attribute(node, 'type') || '').toLowerCase() !== 'checkbox') return '';
        return `<input type="checkbox" disabled${attribute(node, 'checked') === null ? '' : ' checked'}>`;
    }

    const children = serializeChildren(node, baseURL, insideListItem);
    if (!allowedElements.has(name)) return children;
    if (name === 'br' || name === 'hr') return `<${name}>`;

    let attributes = '';
    if (name === 'ol') {
        const start = attribute(node, 'start');
        if (start !== null && /^-?\d+$/.test(start)) {
            attributes += ` start="${escapeHtml(start)}"`;
        }
    } else if (name === 'th' || name === 'td') {
        const align = (attribute(node, 'align') || '').toLowerCase();
        if (align === 'left' || align === 'center' || align === 'right') {
            attributes += ` align="${escapeHtml(align)}"`;
        }
    } else if (name === 'div') {
        const className = (attribute(node, 'class') || '').toLowerCase();
        if (alertClasses.has(className)) attributes += ` class="${escapeHtml(className)}"`;
    } else if (name === 'a') {
        const href = attribute(node, 'href');
        const safe = href === null ? null : resolvedHref(href, baseURL);
        if (safe === null) return children;
        attributes += ` href="${escapeHtml(safe)}"`;
    }
    return `<${name}${attributes}>${children}</${name}>`;
}

function sanitizeHtml(html, itemURL) {
    let baseURL = null;
    if (typeof itemURL === 'string' &&
        /^https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/(?:pull|issues)\/[0-9]+$/.test(itemURL)) {
        const candidate = $.NSURL.URLWithString(itemURL);
        if (!candidate.isNil()) baseURL = candidate;
    }

    const source = `<!doctype html><html><head></head><body>${html}</body></html>`;
    const data = $.NSString.stringWithString(source).dataUsingEncoding($.NSUTF8StringEncoding);
    const document = $.NSXMLDocument.alloc.initWithDataOptionsError(data, HTML_PARSE_OPTIONS, null);
    if (document.isNil()) throw new Error('Markdown HTML could not be parsed');
    const root = document.rootElement;
    if (root.isNil()) throw new Error('Markdown HTML could not be parsed');

    let body = null;
    for (let i = 0; i < Number(root.childCount); i++) {
        const child = root.childAtIndex(i);
        if (Number(child.kind) === ELEMENT_NODE_KIND && String(ObjC.unwrap(child.name)).toLowerCase() === 'body') {
            body = child;
            break;
        }
    }
    if (body === null) throw new Error('Markdown HTML body could not be parsed');
    return serializeChildren(body, baseURL, false);
}


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

function run([libraryPath, itemURL]) {
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
