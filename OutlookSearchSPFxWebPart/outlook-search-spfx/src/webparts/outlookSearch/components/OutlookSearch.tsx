import * as React from 'react';
import { MessageBar, MessageBarType } from '@fluentui/react';
import { IOutlookSearchProps } from './IOutlookSearchProps';
import { IEmailItem, IEmailPreview } from '../models/IEmailItem';
import { AzureSearchService } from '../services/AzureSearchService';
import { SearchBar } from './SearchBar';
import { EmailList } from './EmailList';
import { ReadingPane } from './ReadingPane';
import styles from './OutlookSearch.module.scss';

const LIST_WIDTH_KEY = 'rse-outlookSearch-listWidth';
const LIST_WIDTH_DEFAULT = 360;
const LIST_WIDTH_MIN = 260;
const READING_WIDTH_MIN = 320;

function clampWidth(w: number, containerWidth: number): number {
  const max = Math.max(LIST_WIDTH_MIN, containerWidth - READING_WIDTH_MIN);
  return Math.min(Math.max(w, LIST_WIDTH_MIN), max);
}

function loadListWidth(): number {
  const raw = window.localStorage.getItem(LIST_WIDTH_KEY);
  const n = raw ? parseInt(raw, 10) : NaN;
  return isNaN(n) ? LIST_WIDTH_DEFAULT : n;
}

/** Skip-based paging can return a document again when the index changes
 * between pages (e.g. during a reindex); keep only the first occurrence so
 * a row and its selection highlight can never appear twice. */
function dedupeByPath(items: IEmailItem[]): IEmailItem[] {
  const seen: { [path: string]: boolean } = {};
  return items.filter((item) => {
    if (seen[item.storagePath]) { return false; }
    seen[item.storagePath] = true;
    return true;
  });
}

/** Newest first; undated items sink to the bottom. Guarantees the visible
 * order always matches the displayed dates and group headers. */
function sortByDateDesc(items: IEmailItem[]): IEmailItem[] {
  return items.slice().sort((a, b) => {
    const ta = Date.parse(a.date); const tb = Date.parse(b.date);
    return (isNaN(tb) ? -Infinity : tb) - (isNaN(ta) ? -Infinity : ta);
  });
}

const OutlookSearch: React.FC<IOutlookSearchProps> = (props) => {
  const { httpClient, searchServiceUrl, indexName, apiKey, apiVersion, suggesterName, pageSize, emlPreviewUrl } = props;

  const service = React.useMemo(
    () => new AzureSearchService(httpClient, {
      serviceUrl: searchServiceUrl,
      indexName,
      apiKey,
      apiVersion,
      suggesterName
    }),
    [httpClient, searchServiceUrl, indexName, apiKey, apiVersion, suggesterName]
  );

  const [query, setQuery] = React.useState('');
  const [items, setItems] = React.useState<IEmailItem[]>([]);
  const [totalCount, setTotalCount] = React.useState(0);
  const [broadened, setBroadened] = React.useState(false);
  const [listLoading, setListLoading] = React.useState(false);
  const [listError, setListError] = React.useState<string | undefined>(undefined);
  const [orderByDate, setOrderByDate] = React.useState(true);
  // Set once the user picks a sort themselves; from then on a matter number is left in
  // whatever order they chose rather than quietly switching under them.
  const [sortPinned, setSortPinned] = React.useState(false);
  // True when the last search was a bare matter number and was ranked by relevance for
  // that reason, so the control can explain itself instead of looking wrong.
  const [autoRelevance, setAutoRelevance] = React.useState(false);

  const [selected, setSelected] = React.useState<IEmailItem | undefined>(undefined);
  const [preview, setPreview] = React.useState<IEmailPreview | undefined>(undefined);
  const [fallbackText, setFallbackText] = React.useState<string | undefined>(undefined);
  const [contentLoading, setContentLoading] = React.useState(false);
  const [contentError, setContentError] = React.useState<string | undefined>(undefined);

  const searchSeq = React.useRef(0);

  // ── Adjustable split between list and reading pane ──
  const [listWidth, setListWidth] = React.useState<number>(loadListWidth);
  const panesRef = React.useRef<HTMLDivElement>(null);
  const draggingRef = React.useRef(false);

  const saveListWidth = React.useCallback((w: number): void => {
    try { window.localStorage.setItem(LIST_WIDTH_KEY, String(Math.round(w))); } catch { /* ignore */ }
  }, []);

  const onSplitterPointerDown = React.useCallback((e: React.PointerEvent<HTMLDivElement>): void => {
    draggingRef.current = true;
    e.currentTarget.setPointerCapture(e.pointerId);
    e.preventDefault();
  }, []);

  const onSplitterPointerMove = React.useCallback((e: React.PointerEvent<HTMLDivElement>): void => {
    if (!draggingRef.current || !panesRef.current) { return; }
    const rect = panesRef.current.getBoundingClientRect();
    setListWidth(clampWidth(e.clientX - rect.left, rect.width));
  }, []);

  const onSplitterPointerUp = React.useCallback((e: React.PointerEvent<HTMLDivElement>): void => {
    if (!draggingRef.current) { return; }
    draggingRef.current = false;
    e.currentTarget.releasePointerCapture(e.pointerId);
    setListWidth((w) => { saveListWidth(w); return w; });
  }, [saveListWidth]);

  const onSplitterKeyDown = React.useCallback((e: React.KeyboardEvent<HTMLDivElement>): void => {
    if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') { return; }
    e.preventDefault();
    const delta = e.key === 'ArrowLeft' ? -16 : 16;
    const containerWidth = panesRef.current ? panesRef.current.getBoundingClientRect().width : 1200;
    setListWidth((w) => {
      const next = clampWidth(w + delta, containerWidth);
      saveListWidth(next);
      return next;
    });
  }, [saveListWidth]);

  // allowAuto is passed rather than read from sortPinned: the toggle handler sets that state
  // and searches in the same click, and a state update is not visible to this closure until
  // the next render, so reading it here would let the first explicit sort be overridden by
  // the very auto-behaviour the click was rejecting.
  const runSearch = React.useCallback((
    q: string, skip: number, byDate: boolean, append: boolean, allowAuto: boolean
  ): void => {
    const seq = ++searchSeq.current;
    setListLoading(true);
    setListError(undefined);
    service.search(q, { top: pageSize, skip, orderByDate: byDate, allowAutoRelevance: allowAuto })
      .then((page) => {
        if (seq !== searchSeq.current) { return; } // superseded by a newer search
        // Sort by what the service actually did, not by what was asked. A bare matter
        // number comes back relevance-ranked even though byDate is true, and re-sorting
        // that by date here would undo the ranking before it ever reached the screen.
        const servedByDate = page.orderedByDate !== undefined ? page.orderedByDate : byDate;
        setItems((prev) => {
          const merged = dedupeByPath(append ? prev.concat(page.items) : page.items);
          return servedByDate ? sortByDateDesc(merged) : merged;
        });
        setAutoRelevance(page.matterLookup === true);
        setTotalCount(page.totalCount);
        setBroadened(page.broadened === true);
        setListLoading(false);
        if (!append) {
          setSelected(undefined);
          setPreview(undefined);
          setFallbackText(undefined);
          setContentError(undefined);
        }
      })
      .catch((err: Error) => {
        if (seq !== searchSeq.current) { return; }
        setListLoading(false);
        setListError(err.message);
      });
  }, [service, pageSize]);

  // Initial load: show the most recent messages, like opening an Outlook folder.
  React.useEffect(() => {
    runSearch('', 0, true, false, true);
  }, [runSearch]);

  const handleSearch = React.useCallback((q: string): void => {
    setQuery(q);
    runSearch(q, 0, orderByDate, false, !sortPinned);
  }, [runSearch, orderByDate, sortPinned]);

  const handleToggleSort = React.useCallback((): void => {
    setSortPinned(true);
    setOrderByDate((prev) => {
      runSearch(query, 0, !prev, false, false);
      return !prev;
    });
  }, [runSearch, query]);

  const handleLoadMore = React.useCallback((): void => {
    runSearch(query, items.length, orderByDate, true, !sortPinned);
  }, [runSearch, query, items.length, orderByDate, sortPinned]);

  const handleSelect = React.useCallback((item: IEmailItem): void => {
    setSelected(item);
    setPreview(undefined);
    setFallbackText(undefined);
    setContentError(undefined);
    setContentLoading(true);

    const loadFallback = (): void => {
      service.getContent(item.storagePath)
        .then((text) => { setFallbackText(text); setContentLoading(false); })
        .catch((err: Error) => { setContentError(err.message); setContentLoading(false); });
    };

    if (emlPreviewUrl) {
      service.getPreview(emlPreviewUrl, item.storagePath)
        .then((p) => { setPreview(p); setContentLoading(false); })
        .catch(() => loadFallback()); // degrade to index text if the function is down
    } else {
      loadFallback();
    }
  }, [service, emlPreviewUrl]);

  const getSuggestions = React.useCallback(
    (text: string): Promise<string[]> => service.suggest(text),
    [service]
  );

  if (!searchServiceUrl || !indexName || !apiKey) {
    return (
      <MessageBar messageBarType={MessageBarType.warning}>
        Configure the web part: open the property pane and set the Azure AI Search
        service URL, index name, and query API key.
      </MessageBar>
    );
  }

  return (
    <div className={styles.outlookSearch}>
      <div className={styles.topBar}>
        <SearchBar onSearch={handleSearch} getSuggestions={getSuggestions} />
      </div>

      {listError && (
        <MessageBar messageBarType={MessageBarType.error} isMultiline={true}>
          {listError}
        </MessageBar>
      )}

      {broadened && !listError && (
        <MessageBar messageBarType={MessageBarType.info} isMultiline={false}>
          No message contains every word you typed. Showing messages that match some of them.
        </MessageBar>
      )}

      <div className={styles.panes} ref={panesRef} style={{ display: 'flex', flexDirection: 'row' }}>
        <EmailList
          items={items}
          totalCount={totalCount}
          selectedPath={selected ? selected.storagePath : undefined}
          loading={listLoading}
          orderByDate={orderByDate}
          autoRelevance={autoRelevance}
          hasMore={items.length < totalCount}
          width={listWidth}
          emlPreviewUrl={emlPreviewUrl}
          onSelect={handleSelect}
          onToggleSort={handleToggleSort}
          onLoadMore={handleLoadMore}
        />
        <div
          className={styles.splitter}
          role="separator"
          aria-orientation="vertical"
          aria-label="Resize message list"
          tabIndex={0}
          onPointerDown={onSplitterPointerDown}
          onPointerMove={onSplitterPointerMove}
          onPointerUp={onSplitterPointerUp}
          onKeyDown={onSplitterKeyDown}
        />
        <ReadingPane
          item={selected}
          preview={preview}
          fallbackText={fallbackText}
          emlPreviewUrl={emlPreviewUrl}
          loading={contentLoading}
          error={contentError}
        />
      </div>
    </div>
  );
};

export default OutlookSearch;

