import * as React from 'react';
import { Persona, PersonaSize, Icon, Spinner, SpinnerSize } from '@fluentui/react';
import { IEmailItem, IEmailPreview } from '../models/IEmailItem';
import { displayName, fileTypeIcon } from './EmailList';
import styles from './OutlookSearch.module.scss';

export interface IReadingPaneProps {
  item: IEmailItem | undefined;
  /** Outlook-fidelity preview from the EmlPreviewFunc endpoint. */
  preview: IEmailPreview | undefined;
  /** Plain-text fallback from the index when the preview service is unavailable. */
  fallbackText: string | undefined;
  loading: boolean;
  error: string | undefined;
}

function formatFullDate(iso: string): string {
  const d = new Date(iso);
  if (isNaN(d.getTime())) { return ''; }
  return d.toLocaleDateString(undefined, { weekday: 'short', month: 'numeric', day: 'numeric', year: 'numeric' }) +
    ' ' + d.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
}

function formatSize(bytes: number): string {
  if (bytes >= 1024 * 1024) { return `${(bytes / (1024 * 1024)).toFixed(1)} MB`; }
  if (bytes >= 1024) { return `${Math.round(bytes / 1024)} KB`; }
  return `${bytes} B`;
}

/**
 * Wraps the sanitized email HTML in a minimal document with Outlook's default
 * typography. Rendered in a sandboxed iframe: scripts are blocked by the
 * sandbox, links open in a new tab via <base target>.
 */
function buildSrcDoc(html: string): string {
  return '<!doctype html><html><head><meta charset="utf-8">' +
    '<base target="_blank" rel="noopener noreferrer">' +
    '<style>body{font-family:Aptos,Calibri,"Segoe UI",sans-serif;font-size:11pt;' +
    'color:#242424;margin:0;padding:4px 2px;word-break:break-word;}' +
    'img{max-width:100%;height:auto;}</style>' +
    `</head><body>${html}</body></html>`;
}

export const ReadingPane: React.FC<IReadingPaneProps> = (props) => {
  const { item, preview, fallbackText, loading, error } = props;

  if (!item) {
    return (
      <div className={styles.readingPane}>
        <div className={styles.readingEmpty}>
          <Icon iconName="Mail" className={styles.readingEmptyIcon} />
          <p>Select an item to read</p>
        </div>
      </div>
    );
  }

  const from = preview ? preview.from : item.from;
  const toLine = preview ? preview.to.join('; ') : item.to;
  const ccLine = preview ? preview.cc.join('; ') : item.cc;
  const subject = (preview && preview.subject) || item.subject;
  const date = (preview && preview.date) || item.date;
  const attachments = preview
    ? preview.attachments
    : item.attachmentNames.map((name) => ({ name, sizeBytes: 0 }));

  return (
    <div className={styles.readingPane}>
      <div className={styles.readingSubjectRow}>
        <h2 className={styles.readingSubject}>{subject}</h2>
      </div>

      <div className={styles.readingHeader}>
        <Persona text={displayName(from)} size={PersonaSize.size40} hidePersonaDetails={true} />
        <div className={styles.readingHeaderText}>
          <div className={styles.readingFrom}>{from}</div>
          {toLine && <div className={styles.readingRecipients}>To: {toLine}</div>}
          {ccLine && <div className={styles.readingRecipients}>Cc: {ccLine}</div>}
        </div>
        <div className={styles.readingDate}>{formatFullDate(date)}</div>
      </div>

      {attachments.length > 0 && (
        <div className={styles.attachmentRow}>
          {attachments.map((a) => (
            <span key={a.name} className={styles.attachmentCard}>
              <Icon iconName={fileTypeIcon(a.name)} className={styles.attachmentCardIcon} />
              <span className={styles.attachmentCardText}>
                <span className={styles.attachmentCardName}>{a.name}</span>
                {a.sizeBytes > 0 && (
                  <span className={styles.attachmentCardSize}>{formatSize(a.sizeBytes)}</span>
                )}
              </span>
            </span>
          ))}
        </div>
      )}

      <div className={styles.readingBody}>
        {loading && <Spinner size={SpinnerSize.medium} label="Loading message…" />}
        {!loading && error && <div className={styles.readingError}>{error}</div>}
        {!loading && !error && preview && preview.htmlBody && (
          <iframe
            className={styles.bodyFrame}
            sandbox="allow-popups allow-popups-to-escape-sandbox"
            srcDoc={buildSrcDoc(preview.htmlBody)}
            title={subject || 'Email body'}
          />
        )}
        {!loading && !error && preview && !preview.htmlBody && (
          <pre className={styles.readingText}>{preview.textBody}</pre>
        )}
        {!loading && !error && !preview && (
          fallbackText
            ? <pre className={styles.readingText}>{fallbackText}</pre>
            : <p className={styles.readingNoContent}>No preview is available for this message.</p>
        )}
      </div>
    </div>
  );
};
