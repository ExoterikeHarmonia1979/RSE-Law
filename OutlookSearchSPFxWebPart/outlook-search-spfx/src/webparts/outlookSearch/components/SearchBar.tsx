import * as React from 'react';
import { SearchBox, Icon } from '@fluentui/react';
import { ISuggestion } from '../models/IEmailItem';
import styles from './OutlookSearch.module.scss';

export interface ISearchBarProps {
  /** Called when the user commits a search (Enter, suggestion click, clear). */
  onSearch: (query: string) => void;
  /** Debounced as-you-type callback used to fetch server suggestions. */
  getSuggestions: (text: string) => Promise<string[]>;
}

const RECENT_KEY = 'rse-outlookSearch-recent';
const MAX_RECENT = 5;

function loadRecent(): string[] {
  try {
    const raw = window.localStorage.getItem(RECENT_KEY);
    const parsed = raw ? JSON.parse(raw) : [];
    return Array.isArray(parsed) ? parsed.filter((x) => typeof x === 'string') : [];
  } catch {
    return [];
  }
}

function saveRecent(query: string): void {
  if (!query.trim()) { return; }
  const next = [query, ...loadRecent().filter((q) => q.toLowerCase() !== query.toLowerCase())]
    .slice(0, MAX_RECENT);
  try {
    window.localStorage.setItem(RECENT_KEY, JSON.stringify(next));
  } catch { /* storage disabled — recent searches just won't persist */ }
}

/**
 * Outlook-style search bar: type-ahead suggestions from the index suggester,
 * recent searches when empty, Up/Down + Enter keyboard navigation, and
 * Esc / clear-button behavior matching the Outlook search box.
 */
export const SearchBar: React.FC<ISearchBarProps> = (props) => {
  const { onSearch, getSuggestions } = props;
  const [text, setText] = React.useState('');
  const [open, setOpen] = React.useState(false);
  const [suggestions, setSuggestions] = React.useState<ISuggestion[]>([]);
  const [activeIndex, setActiveIndex] = React.useState(-1);
  const debounceRef = React.useRef<number | undefined>(undefined);
  const latestRequest = React.useRef(0);
  const rootRef = React.useRef<HTMLDivElement>(null);

  const showRecent = React.useCallback((): void => {
    setSuggestions(loadRecent().map((q) => ({ text: q, kind: 'recent' as const })));
    setActiveIndex(-1);
  }, []);

  const commit = React.useCallback((query: string): void => {
    setOpen(false);
    setActiveIndex(-1);
    setText(query);
    saveRecent(query);
    onSearch(query);
  }, [onSearch]);

  const handleChange = React.useCallback((_e?: unknown, newValue?: string): void => {
    const value = newValue || '';
    setText(value);
    setOpen(true);
    if (debounceRef.current !== undefined) {
      window.clearTimeout(debounceRef.current);
    }
    if (!value.trim()) {
      showRecent();
      return;
    }
    debounceRef.current = window.setTimeout(() => {
      const requestId = ++latestRequest.current;
      getSuggestions(value)
        .then((server) => {
          if (requestId !== latestRequest.current) { return; } // stale response
          const recent = loadRecent()
            .filter((q) => q.toLowerCase().indexOf(value.toLowerCase()) !== -1)
            .map((q) => ({ text: q, kind: 'recent' as const }));
          setSuggestions([
            ...recent,
            ...server.map((s) => ({ text: s, kind: 'server' as const }))
          ]);
          setActiveIndex(-1);
        })
        .catch(() => setSuggestions([]));
    }, 250);
  }, [getSuggestions, showRecent]);

  const handleKeyDown = React.useCallback((e: React.KeyboardEvent): void => {
    if (!open || suggestions.length === 0) { return; }
    if (e.key === 'ArrowDown') {
      e.preventDefault();
      setActiveIndex((i) => (i + 1) % suggestions.length);
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      setActiveIndex((i) => (i <= 0 ? suggestions.length - 1 : i - 1));
    } else if (e.key === 'Enter' && activeIndex >= 0) {
      e.preventDefault();
      e.stopPropagation();
      commit(suggestions[activeIndex].text);
    } else if (e.key === 'Escape') {
      setOpen(false);
      setActiveIndex(-1);
    }
  }, [open, suggestions, activeIndex, commit]);

  // Close the flyout when focus leaves the search bar entirely.
  const handleBlur = React.useCallback((e: React.FocusEvent): void => {
    if (rootRef.current && !rootRef.current.contains(e.relatedTarget as Node)) {
      setOpen(false);
    }
  }, []);

  return (
    <div className={styles.searchBar} ref={rootRef} onKeyDown={handleKeyDown} onBlur={handleBlur}>
      <SearchBox
        placeholder="Search"
        value={text}
        onChange={handleChange}
        onFocus={() => { setOpen(true); if (!text.trim()) { showRecent(); } }}
        onSearch={(v) => commit(v || '')}
        onClear={() => { setText(''); showRecent(); onSearch(''); }}
        className={styles.searchBox}
        autoComplete="off"
      />
      {open && suggestions.length > 0 && (
        <div className={styles.suggestFlyout} role="listbox">
          {suggestions.map((s, i) => (
            <button
              key={`${s.kind}-${s.text}`}
              type="button"
              role="option"
              aria-selected={i === activeIndex}
              className={`${styles.suggestItem} ${i === activeIndex ? styles.suggestItemActive : ''}`}
              onMouseDown={(e) => e.preventDefault() /* keep focus in the box */}
              onClick={() => commit(s.text)}
              onMouseEnter={() => setActiveIndex(i)}
            >
              <Icon
                iconName={s.kind === 'recent' ? 'History' : 'Search'}
                className={styles.suggestIcon}
              />
              <span className={styles.suggestText}>{s.text}</span>
            </button>
          ))}
          <div className={styles.suggestHint}>
            Try: <code>from:&quot;Scott Dallas&quot;</code>&nbsp; <code>subject:review</code>&nbsp;
            <code>after:2026-01-01</code>&nbsp; <code>hasattachment:yes</code>
          </div>
        </div>
      )}
    </div>
  );
};
