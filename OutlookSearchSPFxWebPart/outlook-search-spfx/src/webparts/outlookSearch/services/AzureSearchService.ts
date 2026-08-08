import { HttpClient, HttpClientResponse, IHttpClientOptions } from '@microsoft/sp-http';
import { IEmailItem, ISearchPage } from '../models/IEmailItem';
import { parseOutlookQuery } from './OutlookQueryParser';

export interface IAzureSearchConfig {
  serviceUrl: string;   // https://<service>.search.windows.net
  indexName: string;
  apiKey: string;       // query key (not an admin key)
  apiVersion: string;   // e.g. 2024-07-01
  suggesterName: string; // '' disables suggestions
}

export interface ISearchOptions {
  top: number;
  skip: number;
  orderByDate: boolean;
}

// Sentinel highlight tags: everything else in the snippet gets HTML-escaped,
// then these are swapped for real <mark> tags. Email bodies can contain
// arbitrary HTML, so nothing from the index is ever injected unescaped.
const HL_PRE = '\uE000';
const HL_POST = '\uE001';

const SELECT_FIELDS = [
  'content',
  'metadata_storage_path',
  'metadata_storage_name',
  'metadata_storage_last_modified',
  'metadata_message_from',
  'metadata_message_to',
  'metadata_message_cc',
  'metadata_subject',
  'metadata_creation_date'
].join(',');

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function toSnippetHtml(fragments: string[] | undefined): string {
  if (!fragments || fragments.length === 0) {
    return '';
  }
  return escapeHtml(fragments[0])
    .split(HL_PRE).join('<mark>')
    .split(HL_POST).join('</mark>');
}

/* eslint-disable @typescript-eslint/no-explicit-any */
function str(doc: any, field: string): string {
  const v = doc[field];
  return typeof v === 'string' ? v : '';
}

function toEmailItem(doc: any): IEmailItem {
  const highlights = doc['@search.highlights'] || {};
  const attachments = Array.isArray(doc.attachment_names) ? doc.attachment_names : [];
  // Collapse whitespace and keep only the start of the body for the preview
  // line; the full text is re-fetched on selection for the reading pane.
  const bodyPreview = str(doc, 'content').replace(/\s+/g, ' ').trim().slice(0, 200);

  // Meeting invites (and some malformed mails) carry the EVENT date as the
  // .eml creation date, which can be in the future. Trust the creation date
  // only if it's plausible; otherwise use the blob's last-modified time.
  const created = str(doc, 'metadata_creation_date');
  const modified = str(doc, 'metadata_storage_last_modified');
  const createdMs = Date.parse(created);
  const plausible = !isNaN(createdMs) && createdMs <= Date.now() + 60 * 60 * 1000;

  return {
    bodyPreview,
    storagePath: str(doc, 'metadata_storage_path'),
    fileName: str(doc, 'metadata_storage_name'),
    from: str(doc, 'metadata_message_from'),
    to: str(doc, 'metadata_message_to'),
    cc: str(doc, 'metadata_message_cc'),
    subject: str(doc, 'metadata_subject') || str(doc, 'metadata_storage_name'),
    date: plausible ? created : (modified || created),
    snippetHtml: toSnippetHtml(highlights.content),
    attachmentNames: attachments as string[]
  };
}
/* eslint-enable @typescript-eslint/no-explicit-any */

export class AzureSearchService {
  public constructor(
    private readonly _http: HttpClient,
    private readonly _config: IAzureSearchConfig
  ) { }

  /** Full search — powers the message list. */
  public async search(queryText: string, options: ISearchOptions): Promise<ISearchPage> {
    const parsed = parseOutlookQuery(queryText);
    const body: { [key: string]: unknown } = {
      search: parsed.search,
      queryType: 'full',
      searchMode: 'all',
      count: true,
      top: options.top,
      skip: options.skip,
      select: SELECT_FIELDS,
      highlight: 'content,metadata_subject',
      highlightPreTag: HL_PRE,
      highlightPostTag: HL_POST
    };
    if (parsed.filter) {
      body.filter = parsed.filter;
    }
    if (options.orderByDate) {
      // Sort on blob last-modified: creation date is unreliable for meeting
      // invites (event date, possibly future) and would float them to the top.
      body.orderby = 'metadata_storage_last_modified desc';
    }

    const json = await this._post(`/docs/search`, body);
    const values: unknown[] = json.value || [];
    return {
      items: values.map(toEmailItem),
      totalCount: typeof json['@odata.count'] === 'number' ? json['@odata.count'] : values.length
    };
  }

  /**
   * Fetches the extracted text (email body + attachment text) for one
   * document. Done lazily per selection so the list query stays light.
   */
  public async getContent(storagePath: string): Promise<string> {
    const json = await this._post(`/docs/search`, {
      search: '*',
      filter: `metadata_storage_path eq '${storagePath.replace(/'/g, "''")}'`,
      top: 1,
      select: 'content'
    });
    const doc = (json.value && json.value[0]) || {};
    return typeof doc.content === 'string' ? doc.content : '';
  }

  /** Type-ahead suggestions from the index suggester (if one is configured). */
  public async suggest(text: string): Promise<string[]> {
    if (!this._config.suggesterName || text.length < 3) {
      return [];
    }
    try {
      const json = await this._post(`/docs/suggest`, {
        search: text,
        suggesterName: this._config.suggesterName,
        top: 5,
        select: 'metadata_subject'
      });
      const values: { ['@search.text']?: string; metadata_subject?: string }[] = json.value || [];
      const seen: { [k: string]: boolean } = {};
      const out: string[] = [];
      for (const v of values) {
        const s = v.metadata_subject || v['@search.text'] || '';
        if (s && !seen[s.toLowerCase()]) {
          seen[s.toLowerCase()] = true;
          out.push(s);
        }
      }
      return out;
    } catch {
      // A missing suggester should never break typing in the search box.
      return [];
    }
  }

  /* eslint-disable-next-line @typescript-eslint/no-explicit-any */
  private async _post(path: string, body: unknown): Promise<any> {
    const url =
      `${this._config.serviceUrl.replace(/\/+$/, '')}` +
      `/indexes/${encodeURIComponent(this._config.indexName)}${path}` +
      `?api-version=${encodeURIComponent(this._config.apiVersion)}`;

    const options: IHttpClientOptions = {
      headers: {
        'Content-Type': 'application/json',
        'api-key': this._config.apiKey
      },
      body: JSON.stringify(body)
    };

    const response: HttpClientResponse = await this._http.post(url, HttpClient.configurations.v1, options);
    if (!response.ok) {
      let detail = '';
      try {
        const err = await response.json();
        detail = err && err.error && err.error.message ? `: ${err.error.message}` : '';
      } catch { /* body was not JSON */ }
      throw new Error(`Azure AI Search request failed (HTTP ${response.status})${detail}`);
    }
    return response.json();
  }
}
