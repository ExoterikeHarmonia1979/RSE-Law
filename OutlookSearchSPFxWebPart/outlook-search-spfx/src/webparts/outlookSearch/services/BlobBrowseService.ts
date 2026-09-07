import { HttpClient } from '@microsoft/sp-http';
import { IListPage, IProbeResult, ITreeNode } from '../models/ITreeNode';

// A file's kind straight off the wire is only ever trusted if it is one of these —
// anything else (a new kind the function starts sending, a typo, a missing field)
// degrades to 'other' rather than smuggling an unrecognized value past the type
// system, the same way AzureSearchService's toEmailItem trusts no field by default.
const KNOWN_FILE_KINDS: ReadonlyArray<string> = ['eml', 'msg', 'attachment', 'other'];

/* eslint-disable @typescript-eslint/no-explicit-any */
function str(item: any, field: string, fallback = ''): string {
  const v = item[field];
  return typeof v === 'string' ? v : fallback;
}

function num(item: any, field: string): number {
  const v = Number(item[field]);
  return Number.isFinite(v) ? v : 0;
}

function fileKind(item: any): Exclude<ITreeNode['kind'], 'folder'> {
  const v = item.kind;
  return typeof v === 'string' && KNOWN_FILE_KINDS.indexOf(v) >= 0
    ? (v as Exclude<ITreeNode['kind'], 'folder'>)
    : 'other';
}
/* eslint-enable @typescript-eslint/no-explicit-any */

/**
 * Calls MattersBrowseFunc. The browse URL already carries the function key
 * (?code=...), which is why every parameter is appended with '&' — the same rule
 * downloadUrls.ts follows for the preview function.
 */
export class BlobBrowseService {
  public constructor(private readonly _http: HttpClient, private readonly _browseUrl: string) {}

  public async list(prefix: string, cursor?: string): Promise<IListPage> {
    let url = `${this._browseUrl}&op=list&prefix=${encodeURIComponent(prefix)}`;
    if (cursor) { url += `&cursor=${encodeURIComponent(cursor)}`; }

    const response = await this._http.get(url, HttpClient.configurations.v1);
    if (!response.ok) {
      throw new Error(`Could not list that folder (HTTP ${response.status})`);
    }
    const json = await response.json();

    return {
      prefix: typeof json.prefix === 'string' ? json.prefix : prefix,
      folders: (Array.isArray(json.folders) ? json.folders : []).map(
        /* eslint-disable-next-line @typescript-eslint/no-explicit-any */
        (f: any): ITreeNode => ({
          name: str(f, 'name'),
          path: str(f, 'path'),
          kind: 'folder',
          expanded: false
        })
      ),
      files: (Array.isArray(json.files) ? json.files : []).map(
        /* eslint-disable-next-line @typescript-eslint/no-explicit-any */
        (f: any): ITreeNode => ({
          name: str(f, 'name'),
          path: str(f, 'path'),
          kind: fileKind(f),
          sizeBytes: num(f, 'sizeBytes'),
          lastModified: str(f, 'lastModified')
        })
      ),
      cursor: typeof json.cursor === 'string' && json.cursor ? json.cursor : undefined
    };
  }

  public async probe(prefix: string): Promise<IProbeResult> {
    const url = `${this._browseUrl}&op=probe&prefix=${encodeURIComponent(prefix)}`;
    const response = await this._http.get(url, HttpClient.configurations.v1);
    if (!response.ok) {
      throw new Error(`Could not check that folder (HTTP ${response.status})`);
    }
    const json = await response.json();
    return {
      files: Number(json.files) || 0,
      bytes: Number(json.bytes) || 0,
      withinLimit: json.withinLimit === true,
      fileLimit: Number(json.fileLimit) || 0,
      byteLimit: Number(json.byteLimit) || 0
    };
  }

  /** A navigation target, not a fetch: the zip streams and must not buffer in the page. */
  public zipUrl(prefix: string): string {
    return `${this._browseUrl}&op=zip&prefix=${encodeURIComponent(prefix)}`;
  }
}
