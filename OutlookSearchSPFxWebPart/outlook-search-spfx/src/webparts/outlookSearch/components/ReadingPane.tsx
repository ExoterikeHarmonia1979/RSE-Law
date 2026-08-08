import * as React from 'react';
import { Persona, PersonaSize, Icon, Spinner, SpinnerSize, Link } from '@fluentui/react';
import { IEmailItem } from '../models/IEmailItem';
import { displayName } from './EmailList';
import styles from './OutlookSearch.module.scss';

export interface IReadingPaneProps {
  item: IEmailItem | undefined;
  /** Extracted text of the email body + attachments; undefined while loading. */
  content: string | undefined;
  loading: boolean;
  error: string | undefined;
}

function formatFullDate(iso: string): string {
  const d = new Date(iso);
  if (isNaN(d.getTime())) { return ''; }
  return d.toLocaleDateString(undefined, { weekday: 'short', month: 'numeric', day: 'numeric', year: 'numeric' }) +
    ' ' + d.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
}

export const ReadingPane: React.FC<IReadingPaneProps> = (props) => {
  const { item, content, loading, error } = props;

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

  return (
    <div className={styles.readingPane}>
      <div className={styles.readingSubjectRow}>
        <h2 className={styles.readingSubject}>{item.subject}</h2>
      </div>

      <div className={styles.readingHeader}>
        <Persona text={displayName(item.from)} size={PersonaSize.size40} hidePersonaDetails={true} />
        <div className={styles.readingHeaderText}>
          <div className={styles.readingFrom}>{displayName(item.from)}</div>
          {item.to && <div className={styles.readingRecipients}>To: {item.to}</div>}
          {item.cc && <div className={styles.readingRecipients}>Cc: {item.cc}</div>}
        </div>
        <div className={styles.readingDate}>{formatFullDate(item.date)}</div>
      </div>

      {item.attachmentNames.length > 0 && (
        <div className={styles.attachmentRow}>
          {item.attachmentNames.map((name) => (
            <span key={name} className={styles.attachmentChip}>
              <Icon iconName="Attach" /> {name}
            </span>
          ))}
        </div>
      )}

      <div className={styles.readingMeta}>
        <Icon iconName="Mail" />
        <span>{item.fileName}</span>
        {item.storagePath && item.storagePath.indexOf('https://') === 0 && (
          <Link href={item.storagePath} target="_blank" rel="noopener noreferrer">
            Open source .eml
          </Link>
        )}
      </div>

      <div className={styles.readingBody}>
        {loading && <Spinner size={SpinnerSize.medium} label="Loading message…" />}
        {!loading && error && <div className={styles.readingError}>{error}</div>}
        {!loading && !error && (
          content
            ? <pre className={styles.readingText}>{content}</pre>
            : <p className={styles.readingNoContent}>
                No extracted text is available for this message. Check that the indexer&apos;s
                <code> dataToExtract</code> setting is <code>contentAndMetadata</code>.
              </p>
        )}
      </div>
    </div>
  );
};
