/**
 * A single .eml document as returned by the Azure AI Search index.
 * Field names follow the defaults produced by the Azure blob indexer
 * when it cracks message/rfc822 (.eml) files.
 */
export interface IEmailItem {
  /** Value of metadata_storage_path — used to look the document back up. */
  storagePath: string;
  fileName: string;
  from: string;
  to: string;
  cc: string;
  subject: string;
  /** ISO 8601 date (metadata_creation_date, falling back to last modified). */
  date: string;
  /** Hit-highlighted snippet, already HTML-escaped except for <mark> tags. */
  snippetHtml: string;
  attachmentNames: string[];
}

export interface ISearchPage {
  items: IEmailItem[];
  totalCount: number;
}

export interface ISuggestion {
  text: string;
  /** 'recent' = from localStorage history, 'server' = from the suggester. */
  kind: 'recent' | 'server';
}
