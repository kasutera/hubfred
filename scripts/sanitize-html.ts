ObjC.import('Foundation');

const HTML_ESCAPES: Record<string, string> = {
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
};

export function escapeHtml(value: string): string {
    return value.replace(/[&<>"']/g, character => HTML_ESCAPES[character] ?? character);
}

const HTML_PARSE_OPTIONS = $.NSXMLDocumentTidyHTML | $.NSXMLNodeLoadExternalEntitiesNever;
const ELEMENT_NODE_KIND = Number($.NSXMLElementKind);
const TEXT_NODE_KIND = Number($.NSXMLTextKind);
const allowedElements: Record<string, true> = {
    p: true, br: true, hr: true, h1: true, h2: true, h3: true, h4: true, h5: true, h6: true,
    strong: true, em: true, del: true, blockquote: true, ul: true, ol: true, li: true, pre: true, code: true,
    table: true, thead: true, tbody: true, tr: true, th: true, td: true, div: true, input: true, a: true
};
const removedContentElements: Record<string, true> = {
    applet: true, base: true, canvas: true, embed: true, frame: true, frameset: true, head: true, iframe: true,
    math: true, meta: true, noembed: true, noframes: true, noscript: true, object: true, plaintext: true,
    script: true, style: true, svg: true, template: true, title: true, xmp: true
};
const alertClasses: Record<string, true> = {
    note: true, tip: true, important: true, warning: true, caution: true
};

function attribute(node: JXAXMLNode, name: string): string | null {
    const value = node.attributeForName(name);
    return value.isNil() ? null : ObjC.unwrap(value.stringValue);
}

function resolvedHref(href: string, baseURL: JXAURL | null): string | null {
    if (baseURL === null || baseURL.isNil() || /[\x00-\x20\x7f\\]/.test(href)) return null;
    const url = $.NSURL.URLWithStringRelativeToURL($.NSString.stringWithString(href), baseURL);
    if (url.isNil()) return null;
    const absolute = url.absoluteURL;
    const scheme = ObjC.unwrap(absolute.scheme);
    const host = ObjC.unwrap(absolute.host);
    if (!scheme || !/^https?$/i.test(scheme) || !host) return null;
    return ObjC.unwrap(absolute.absoluteString);
}

function serializeChildren(node: JXAXMLNode, baseURL: JXAURL | null, inListItem: boolean): string {
    let result = '';
    for (let i = 0; i < Number(node.childCount); i++) {
        result += serializeNode(node.childAtIndex(i), baseURL, inListItem);
    }
    return result;
}

function serializeNode(node: JXAXMLNode, baseURL: JXAURL | null, inListItem: boolean): string {
    const kind = Number(node.kind);
    if (kind === TEXT_NODE_KIND) return escapeHtml(ObjC.unwrap(node.stringValue));
    if (kind !== ELEMENT_NODE_KIND) return '';

    const name = String(ObjC.unwrap(node.name)).toLowerCase();
    if (removedContentElements[name] === true) return '';
    const insideListItem = inListItem || name === 'li';
    if (name === 'input') {
        if (!inListItem || (attribute(node, 'type') || '').toLowerCase() !== 'checkbox') return '';
        return `<input type="checkbox" disabled${attribute(node, 'checked') === null ? '' : ' checked'}>`;
    }

    const children = serializeChildren(node, baseURL, insideListItem);
    if (allowedElements[name] !== true) return children;
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
        if (alertClasses[className] === true) attributes += ` class="${escapeHtml(className)}"`;
    } else if (name === 'a') {
        const href = attribute(node, 'href');
        const safe = href === null ? null : resolvedHref(href, baseURL);
        if (safe === null) return children;
        attributes += ` href="${escapeHtml(safe)}"`;
    }
    return `<${name}${attributes}>${children}</${name}>`;
}

export function sanitizeHtml(html: string, itemURL: string | undefined): string {
    let baseURL: JXAURL | null = null;
    if (typeof itemURL === 'string' &&
        /^https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/(?:pull|issues)\/[0-9]+$/.test(itemURL)) {
        const candidate = $.NSURL.URLWithString($.NSString.stringWithString(itemURL));
        if (!candidate.isNil()) baseURL = candidate;
    }

    const source = '<!doctype html><html><head><meta http-equiv="Content-Type" content="text/html; charset=UTF-8"></head><body>' +
        html + '</body></html>';
    const data = $.NSString.stringWithString(source).dataUsingEncoding($.NSUTF8StringEncoding);
    const document = $.NSXMLDocument.alloc.initWithDataOptionsError(data, HTML_PARSE_OPTIONS, null);
    if (document.isNil()) throw new Error('Markdown HTML could not be parsed');
    const root = document.rootElement;
    if (root.isNil()) throw new Error('Markdown HTML could not be parsed');

    let body: JXAXMLNode | null = null;
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
