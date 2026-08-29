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
  /** First ~200 chars of the extracted body, for the list preview line. */
  bodyPreview: string;
  attachmentNames: string[];
}

export interface ISearchPage {
  items: IEmailItem[];
  totalCount: number;
  /**
   * True when an exact "every word must match" search found nothing and the
   * service retried with "any word". The UI says so, because silently changing
   * what was asked for is worse than returning nothing.
   */
  broadened?: boolean;
  /**
   * The ordering the service actually applied. The caller merges pages and re-sorts
   * client-side, so it has to sort by the same rule the server used — re-sorting a
   * relevance-ranked result by date would discard the ranking.
   */
  orderedByDate?: boolean;
  /**
   * True when the query was a bare matter number and was ranked by relevance
   * automatically. Surfaced so the sort control can say why it changed.
   */
  matterLookup?: boolean;
}

export interface IPreviewAttachment {
  name: string;
  sizeBytes: number;
}

/** Outlook-fidelity preview returned by the EmlPreviewFunc Azure Function. */
export interface IEmailPreview {
  subject: string;
  from: string;
  to: string[];
  cc: string[];
  date: string;
  /** Sanitized HTML body (cid: images inlined); undefined when the mail is plain text. */
  htmlBody: string | undefined;
  textBody: string;
  attachments: IPreviewAttachment[];
}

export interface ISuggestion {
  text: string;
  /** 'recent' = from localStorage history, 'server' = from the suggester. */
  kind: 'recent' | 'server';
}
