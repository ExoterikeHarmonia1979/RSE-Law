import * as React from 'react';
import { Persona, PersonaSize, Icon, Spinner, SpinnerSize, DefaultButton, TooltipHost } from '@fluentui/react';
import { IEmailItem } from '../models/IEmailItem';
import { emlDownloadUrl, attachmentUrl } from '../services/downloadUrls';
import styles from './OutlookSearch.module.scss';

export interface IEmailListProps {
  items: IEmailItem[];
  totalCount: number;
  selectedPath: string | undefined;
  loading: boolean;
  orderByDate: boolean;
  /** The last search was a bare file number and was ranked by relevance for that reason. */
  autoRelevance: boolean;
  hasMore: boolean;
  /** Pane width in px — controlled by the splitter in OutlookSearch. */
  width: number;
  /** EmlPreviewFunc endpoint (incl. ?code=); '' renders chips non-clickable. */
  emlPreviewUrl: string;
  onSelect: (item: IEmailItem) => void;
  onToggleSort: () => void;
  onLoadMore: () => void;
}

/** "Scott Dallas <dallas@rse-law.com>" → "Scott Dallas" */
export function displayName(address: string): string {
  const match = /^"?([^"<]+)"?\s*</.exec(address);
  const name = match ? match[1].trim() : address.replace(/[<>]/g, '').trim();
  return name || 'Unknown sender';
}

function formatTime(iso: string): string {
  const d = new Date(iso);
  if (isNaN(d.getTime())) { return ''; }
  const now = new Date();
  const sameDay = d.toDateString() === now.toDateString();
  return sameDay
    ? d.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' })
    : d.toLocaleDateString(undefined, { month: 'numeric', day: 'numeric', year: '2-digit' });
}

/** Fluent icon name for an attachment chip, based on file extension. */
export function fileTypeIcon(name: string): string {
  const ext = (name.split('.').pop() || '').toLowerCase();
  switch (ext) {
    case 'xls': case 'xlsx': case 'csv': return 'ExcelDocument';
    case 'doc': case 'docx': return 'WordDocument';
    case 'ppt': case 'pptx': return 'PowerPointDocument';
    case 'pdf': return 'PDF';
    case 'jpg': case 'jpeg': case 'png': case 'gif': case 'bmp': case 'tif': case 'tiff': return 'Photo2';
    case 'msg': case 'eml': return 'Mail';
    case 'zip': case '7z': case 'rar': return 'ZipFolder';
    default: return 'Page';
  }
}

/** Office-brand colors so attachment icons read like Outlook's. */
export function fileTypeColor(name: string): string {
  const ext = (name.split('.').pop() || '').toLowerCase();
  switch (ext) {
    case 'xls': case 'xlsx': case 'csv': return '#107c41'; // Excel green
    case 'doc': case 'docx': return '#185abd';             // Word blue
    case 'ppt': case 'pptx': return '#c43e1c';             // PowerPoint orange
    case 'pdf': return '#b30b00';                          // Acrobat red
    case 'jpg': case 'jpeg': case 'png': case 'gif': case 'bmp': case 'tif': case 'tiff': return '#8764b8';
    case 'msg': case 'eml': return '#0f6cbd';
    case 'zip': case '7z': case 'rar': return '#8a8886';
    default: return '#605e5c';
  }
}

const MAX_LIST_CHIPS = 3;

/** Outlook-style date buckets: Today, Yesterday, This Week, Last Week, ... */
function dateGroup(iso: string): string {
  const d = new Date(iso);
  if (isNaN(d.getTime())) { return 'Undated'; }
  const now = new Date();
  const startOfDay = (x: Date): number => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime();
  const dayMs = 24 * 60 * 60 * 1000;
  const diffDays = Math.floor((startOfDay(now) - startOfDay(d)) / dayMs);

  // Delayed-delivery emails carry a future Date: header (the scheduled send
  // time) — label them instead of lumping them into Today.
  if (diffDays < 0) { return 'Scheduled'; }
  if (diffDays === 0) { return 'Today'; }
  if (diffDays === 1) { return 'Yesterday'; }
  // Weeks starting Monday, matching the firm's calendar convention.
  const mondayOffset = (now.getDay() + 6) % 7;
  if (diffDays <= mondayOffset) { return 'This Week'; }
  if (diffDays <= mondayOffset + 7) { return 'Last Week'; }
  if (d.getFullYear() === now.getFullYear() && d.getMonth() === now.getMonth()) { return 'This Month'; }
  return d.toLocaleDateString(undefined, { month: 'long', year: 'numeric' });
}

export const EmailList: React.FC<IEmailListProps> = (props) => {
  const {
    items, totalCount, selectedPath, loading, orderByDate, autoRelevance,
    hasMore, width, emlPreviewUrl, onSelect, onToggleSort, onLoadMore
  } = props;

  let lastGroup: string | undefined;

  return (
    <div className={styles.listPane} style={{ flex: `0 0 ${width}px`, width: `${width}px` }}>
      <div className={styles.listHeader}>
        <span className={styles.listTitle}>
          Results{totalCount > 0 ? ` (${totalCount.toLocaleString()})` : ''}
        </span>
        {/* "By Date" / "Top Results" read as display options, so nobody realised the first
            was discarding relevance entirely. These name what the ordering IS. */}
        <button
          type="button"
          className={styles.sortToggle}
          onClick={onToggleSort}
          title={
            autoRelevance
              ? 'A file number on its own is ranked by best match, because the daily billing and deadline digests mention every matter and would otherwise fill the newest results. Click to sort by date instead.'
              : (orderByDate ? 'Sorted newest first. Click to rank by best match.' : 'Ranked by best match. Click to sort newest first.')
          }
        >
          {orderByDate ? 'Newest first' : 'Best match'}
          {autoRelevance && <span className={styles.sortAuto}>auto</span>}
          <Icon iconName="ChevronDown" />
        </button>
      </div>

      <div className={styles.listScroll} role="list">
        {loading && items.length === 0 && (
          <Spinner size={SpinnerSize.large} label="Searching…" className={styles.listSpinner} />
        )}

        {!loading && items.length === 0 && (
          <div className={styles.emptyList}>
            <Icon iconName="Search" className={styles.emptyIcon} />
            <p>No results. Try different keywords or prefixes like <code>from:</code>.</p>
          </div>
        )}

        {items.map((item) => {
          const group = orderByDate ? dateGroup(item.date) : undefined;
          const showGroup = group !== undefined && group !== lastGroup;
          if (group !== undefined) { lastGroup = group; }
          const selected = item.storagePath === selectedPath;
          const sender = displayName(item.from);

          return (
            <React.Fragment key={item.storagePath}>
              {showGroup && <div className={styles.groupHeader}>{group}</div>}
              <div
                role="listitem"
                tabIndex={0}
                className={`${styles.listItem} ${selected ? styles.listItemSelected : ''}`}
                onClick={() => onSelect(item)}
                onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); onSelect(item); } }}
              >
                {emlPreviewUrl && (
                  <a
                    className={styles.itemDownload}
                    href={emlDownloadUrl(emlPreviewUrl, item.storagePath)}
                    title="Download this message as a .eml file, with its attachments"
                    aria-label={`Download ${item.subject || item.fileName}`}
                    /* the row's own click selects it — downloading should not also
                       change what is open in the reading pane */
                    onClick={(e) => e.stopPropagation()}
                  >
                    <Icon iconName="Download" />
                  </a>
                )}
                <Persona
                  text={sender}
                  size={PersonaSize.size32}
                  hidePersonaDetails={true}
                  className={styles.itemPersona}
                />
                <div className={styles.itemBody}>
                  <div className={styles.itemTopRow}>
                    <span className={styles.itemSender}>{sender}</span>
                    {item.attachmentNames.length > 0 && (
                      <Icon iconName="Attach" className={styles.attachIcon} />
                    )}
                  </div>
                  <div className={styles.itemSubjectRow}>
                    <span className={styles.itemSubject}>{item.subject}</span>
                    <span className={styles.itemTime}>{formatTime(item.date)}</span>
                  </div>
                  {item.snippetHtml
                    ? <div className={styles.itemSnippet} dangerouslySetInnerHTML={{ __html: item.snippetHtml }} />
                    : <div className={styles.itemSnippet}>{item.bodyPreview || item.fileName}</div>}
                  {item.attachmentNames.length > 0 && (
                    <div className={styles.itemAttachRow}>
                      {item.attachmentNames.slice(0, MAX_LIST_CHIPS).map((name) => (
                        <TooltipHost content={name} key={name}>
                          {emlPreviewUrl ? (
                            <a
                              className={styles.itemAttachChip}
                              href={attachmentUrl(emlPreviewUrl, item.storagePath, name, false)}
                              target="_blank"
                              rel="noopener noreferrer"
                              onClick={(e) => e.stopPropagation() /* open the file, don't just select the row */}
                            >
                              <Icon iconName={fileTypeIcon(name)} className={styles.itemAttachChipIcon} style={{ color: fileTypeColor(name) }} />
                              <span className={styles.itemAttachChipName}>{name}</span>
                            </a>
                          ) : (
                            <span className={styles.itemAttachChip}>
                              <Icon iconName={fileTypeIcon(name)} className={styles.itemAttachChipIcon} style={{ color: fileTypeColor(name) }} />
                              <span className={styles.itemAttachChipName}>{name}</span>
                            </span>
                          )}
                        </TooltipHost>
                      ))}
                      {item.attachmentNames.length > MAX_LIST_CHIPS && (
                        <span className={styles.itemAttachMore}>
                          +{item.attachmentNames.length - MAX_LIST_CHIPS}
                        </span>
                      )}
                    </div>
                  )}
                </div>
              </div>
            </React.Fragment>
          );
        })}

        {hasMore && items.length > 0 && (
          <div className={styles.loadMoreRow}>
            <DefaultButton text={loading ? 'Loading…' : 'Load more'} disabled={loading} onClick={onLoadMore} />
          </div>
        )}
      </div>
    </div>
  );
};

