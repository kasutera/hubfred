interface JXANil {
    isNil(): boolean;
}

interface JXAString extends JXANil {
    dataUsingEncoding(encoding: number): JXAData;
    lengthOfBytesUsingEncoding(encoding: number): number;
}

interface JXAData extends JXANil {
    readonly length: number;
    appendData(data: JXAData): void;
}

interface JXAURL extends JXANil {
    readonly absoluteURL: JXAURL;
    readonly absoluteString: JXAString;
    readonly host: JXAString;
    readonly scheme: JXAString;
}

interface JXAAttribute extends JXANil {
    readonly stringValue: JXAString;
}

interface JXAXMLNode extends JXANil {
    readonly childCount: number;
    readonly kind: number;
    readonly name: JXAString;
    readonly stringValue: JXAString;
    attributeForName(name: string): JXAAttribute;
    childAtIndex(index: number): JXAXMLNode;
}

interface JXAFileHandle {
    readDataOfLength(length: number): JXAData;
}

interface JXAXMLDocument extends JXANil {
    readonly childCount: number;
    readonly rootElement: JXAXMLNode;
    childAtIndex(index: number): JXAXMLNode;
}

interface JXAFoundation {
    readonly NSUTF8StringEncoding: number;
    readonly NSXMLDocumentTidyHTML: number;
    readonly NSXMLNodeLoadExternalEntitiesNever: number;
    readonly NSXMLElementKind: number;
    readonly NSXMLTextKind: number;
    readonly NSString: {
        stringWithString(value: string): JXAString;
        stringWithContentsOfFileEncodingError(path: string, encoding: number, error: null): JXAString;
        alloc: {
            initWithDataEncoding(data: JXAData, encoding: number): JXAString | null;
        };
    };
    readonly NSURL: {
        URLWithString(value: JXAString): JXAURL;
        URLWithStringRelativeToURL(value: JXAString, baseURL: JXAURL): JXAURL;
    };
    readonly NSXMLDocument: {
        alloc: {
            initWithDataOptionsError(data: JXAData, options: number, error: null): JXAXMLDocument;
        };
    };
    readonly NSFileHandle: {
        readonly fileHandleWithStandardInput: JXAFileHandle;
    };
    readonly NSMutableData: {
        readonly alloc: {
            readonly init: JXAData;
        };
    };
}

declare const $: JXAFoundation;

declare const ObjC: {
    import(framework: string): void;
    unwrap(value: JXAString): string;
};
