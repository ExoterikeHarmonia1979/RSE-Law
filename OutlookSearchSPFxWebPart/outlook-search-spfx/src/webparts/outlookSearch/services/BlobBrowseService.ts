import { HttpClient } from '@microsoft/sp-http';
import { IListPage, IProbeResult, ITreeNode } from '../models/ITreeNode';

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
        (f: { name: string; path: string }): ITreeNode => ({
          name: f.name,
          path: f.path,
          kind: 'folder',
          expanded: false
        })
      ),
      files: (Array.isArray(json.files) ? json.files : []).map(
        (f: { name: string; path: string; sizeBytes: number; lastModified: string; kind: ITreeNode['kind'] }): ITreeNode => ({
          name: f.name,
          path: f.path,
          kind: f.kind,
          sizeBytes: f.sizeBytes,
          lastModified: f.lastModified
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
