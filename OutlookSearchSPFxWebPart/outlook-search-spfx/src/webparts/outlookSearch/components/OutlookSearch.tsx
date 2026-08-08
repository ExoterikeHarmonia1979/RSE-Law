import * as React from 'react';
import { MessageBar, MessageBarType } from '@fluentui/react';
import { IOutlookSearchProps } from './IOutlookSearchProps';
import { IEmailItem } from '../models/IEmailItem';
import { AzureSearchService } from '../services/AzureSearchService';
import { SearchBar } from './SearchBar';
import { EmailList } from './EmailList';
import { ReadingPane } from './ReadingPane';
import styles from './OutlookSearch.module.scss';

const OutlookSearch: React.FC<IOutlookSearchProps> = (props) => {
  const { httpClient, searchServiceUrl, indexName, apiKey, apiVersion, suggesterName, pageSize } = props;

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
  const [listLoading, setListLoading] = React.useState(false);
  const [listError, setListError] = React.useState<string | undefined>(undefined);
  const [orderByDate, setOrderByDate] = React.useState(true);

  const [selected, setSelected] = React.useState<IEmailItem | undefined>(undefined);
  const [content, setContent] = React.useState<string | undefined>(undefined);
  const [contentLoading, setContentLoading] = React.useState(false);
  const [contentError, setContentError] = React.useState<string | undefined>(undefined);

  const searchSeq = React.useRef(0);

  const runSearch = React.useCallback((q: string, skip: number, byDate: boolean, append: boolean): void => {
    const seq = ++searchSeq.current;
    setListLoading(true);
    setListError(undefined);
    service.search(q, { top: pageSize, skip, orderByDate: byDate })
      .then((page) => {
        if (seq !== searchSeq.current) { return; } // superseded by a newer search
        setItems((prev) => append ? prev.concat(page.items) : page.items);
        setTotalCount(page.totalCount);
        setListLoading(false);
        if (!append) {
          setSelected(undefined);
          setContent(undefined);
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
    runSearch('', 0, true, false);
  }, [runSearch]);

  const handleSearch = React.useCallback((q: string): void => {
    setQuery(q);
    runSearch(q, 0, orderByDate, false);
  }, [runSearch, orderByDate]);

  const handleToggleSort = React.useCallback((): void => {
    setOrderByDate((prev) => {
      runSearch(query, 0, !prev, false);
      return !prev;
    });
  }, [runSearch, query]);

  const handleLoadMore = React.useCallback((): void => {
    runSearch(query, items.length, orderByDate, true);
  }, [runSearch, query, items.length, orderByDate]);

  const handleSelect = React.useCallback((item: IEmailItem): void => {
    setSelected(item);
    setContent(undefined);
    setContentError(undefined);
    setContentLoading(true);
    service.getContent(item.storagePath)
      .then((text) => { setContent(text); setContentLoading(false); })
      .catch((err: Error) => { setContentError(err.message); setContentLoading(false); });
  }, [service]);

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

      <div className={styles.panes}>
        <EmailList
          items={items}
          totalCount={totalCount}
          selectedPath={selected ? selected.storagePath : undefined}
          loading={listLoading}
          orderByDate={orderByDate}
          hasMore={items.length < totalCount}
          onSelect={handleSelect}
          onToggleSort={handleToggleSort}
          onLoadMore={handleLoadMore}
        />
        <ReadingPane
          item={selected}
          content={content}
          loading={contentLoading}
          error={contentError}
        />
      </div>
    </div>
  );
};

export default OutlookSearch;
