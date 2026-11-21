import { convertMarkdown } from './convert-markdown';
import type { MarkedApi } from './convert-markdown';

const MAX_MARKDOWN_BYTES = 128 * 1024;
const inputError = 'Markdown input too large';

function readMarkdown(): string {
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

function loadMarked(libraryPath: string): MarkedApi {
    const library = ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(
        libraryPath, $.NSUTF8StringEncoding, null));
    const module: {exports: unknown} = {exports: {}};
    new Function('module', 'exports', library)(module, module.exports);
    return module.exports as MarkedApi;
}

export function run([libraryPath, itemURL]: string[]): string {
    const marked = loadMarked(libraryPath);
    const markdown = readMarkdown();
    return convertMarkdown(markdown, itemURL, marked);
}
