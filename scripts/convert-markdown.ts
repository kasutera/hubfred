import type { RendererObject, Tokens, Tokenizer } from 'marked';
import { escapeHtml, sanitizeHtml } from './sanitize-html';

export type MarkedApi = Pick<typeof import('marked'), 'Tokenizer' | 'Marked'>;
type MarkedTokenizer = Tokenizer;

const attachment = /^(?:https:\/\/github\.com)?\/user-attachments\/assets\/[0-9a-f-]+$/i;
const MAX_TABLE_COLUMNS = 128;
const MAX_TABLE_CELLS = 8192;
const MAX_HTML_BYTES = 512 * 1024;


function safeHref(href: string): boolean {
    return !/[\x00-\x20\x7f\\]/.test(href) &&
        (!/^[^/?#]*:/.test(href) || /^https?:\/\//i.test(href));
}

function anchor(href: string, label: string): string {
    return safeHref(href) ? `<a href="${escapeHtml(href)}">${label}</a>` : label;
}

function attachmentLink(href: string): string {
    return anchor(href.startsWith('/') ? `https://github.com${href}` : href,
        'Open attachment in browser');
}

// Accept only a standalone img tag for GitHub attachments. Rebuild the link
// instead of copying attributes or allowing any raw HTML into WebKit.
function rawAttachment(tag: string): string {
    const match = /^\s*<img\s+((?:[^"'<>]|"[^"]*"|'[^']*')*)>\s*$/i.exec(tag);
    if (!match) return '';
    const attributes = /([^\s=/'"<>]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/g;
    let attribute: RegExpExecArray | null;
    while ((attribute = attributes.exec(match[1])) !== null) {
        if (attribute[1].toLowerCase() !== 'src') continue;
        const href = attribute[2] ?? attribute[3] ?? attribute[4] ?? '';
        return attachment.test(href) ? attachmentLink(href) : '';
    }
    return '';
}

// Match Marked's splitCells() pipe escaping when counting header columns.
function countCells(row: string): number {
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

interface TableState {
    cells: number;
}

function checkTableLimits(tokenizer: MarkedTokenizer, source: string, state: TableState): void {
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

const outputError = 'Markdown output too large';

export function convertMarkdown(markdown: string, itemURL: string | undefined, marked: MarkedApi): string {
    const state = {cells: 0};
    const tokenizer = new marked.Tokenizer();
    const originalTable = tokenizer.table;
    tokenizer.table = function(source: string): Tokens.Table | undefined {
        checkTableLimits(this, source, state);
        return originalTable.call(this, source);
    };
    let insideLink = false;
    const renderer: RendererObject = {
        html({text}: Tokens.HTML | Tokens.Tag) { return insideLink ? '' : rawAttachment(text); },
        image({href, text}: Tokens.Image) {
            const label = escapeHtml(text || 'Open image in browser');
            if (insideLink) return label;
            return attachment.test(href) ? attachmentLink(href) : anchor(href, label);
        },
        link({href, tokens}: Tokens.Link) {
            insideLink = true;
            try {
                return anchor(href, this.parser.parseInline(tokens));
            } finally {
                insideLink = false;
            }
        },
        blockquote({tokens}: Tokens.Blockquote) {
            const html = this.parser.parse(tokens);
            const alert = /^<p>\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\](?:\r?\n|<\/p>\s*|$)/.exec(html);
            if (!alert) return `<blockquote>\n${html}</blockquote>\n`;
            const kind = alert[1].toLowerCase();
            const label = kind[0].toUpperCase() + kind.slice(1);
            const contents = html.slice(alert[0].length);
            const start = alert[0].includes('</p>') ? '' : '<p>';
            return `<div class="${kind}"><p><strong>${label}</strong></p>${start}${contents}</div>\n`;
        }
    };
    const parser = new marked.Marked({gfm: true, tokenizer, renderer});
    const html = parser.parse(markdown, {async: false});
    const htmlBytes = $.NSString.stringWithString(html).lengthOfBytesUsingEncoding($.NSUTF8StringEncoding);
    if (htmlBytes > MAX_HTML_BYTES) throw new Error(outputError);
    const sanitized = sanitizeHtml(html, itemURL);
    const sanitizedBytes = $.NSString.stringWithString(sanitized).lengthOfBytesUsingEncoding($.NSUTF8StringEncoding);
    if (sanitizedBytes > MAX_HTML_BYTES) throw new Error(outputError);
    return sanitized;
}
