import * as React from 'react';
import { List, Icon, IconButton, SearchBox, Spinner, SpinnerSize, MessageBar, MessageBarType, MessageBarButton, Dialog, DialogType, DialogFooter, PrimaryButton } from '@fluentui/react';
import { ITreeNode, ITreeRow, IProbeResult, flattenVisible, filterRoots } from '../models/ITreeNode';
import { BlobBrowseService } from '../services/BlobBrowseService';
import { fileTypeIcon, fileTypeColor } from './EmailList';
import styles from './OutlookSearch.module.scss';

export interface IFileTreeProps {
  service: BlobBrowseService;
  /** Pane width in px — controlled by the splitter in OutlookSearch. */
  width: number;
  selectedPath: string | undefined;
  /** An .eml or .msg was clicked: show it in the reading pane. */
  onSelectMessage: (path: string, name: string) => void;
  /** A file's download control (or an attachment row) was clicked. */
  onDownloadFile: (path: string) => void;
}

export function formatSize(bytes: number): string {
  if (!bytes) { return ''; }
  if (bytes < 1024) { return `${bytes} B`; }
  if (bytes < 1024 * 1024) { return `${(bytes / 1024).toFixed(1)} KB`; }
  if (bytes < 1024 * 1024 * 1024) { return `${(bytes / (1024 * 1024)).toFixed(1)} MB`; }
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(1)} GB`;
}

/**
 * The refusal text. The probe stops counting at the cap, so its numbers are lower
 * bounds and must never be printed as totals.
 */
export function capMessage(result: IProbeResult): string {
  const limitFiles = result.fileLimit.toLocaleString();
  const limitSize = formatSize(result.byteLimit);
  return `This folder holds more than ${limitFiles} files or more than ${limitSize}, `
       + `which is too much for a single archive. Open a folder inside it and download that instead.`;
}

/** What the probe dialog shows. Two distinct outcomes, each with its own title, so an
 * expired function key or a network fault is never told to the user as "too large" — a
 * real size refusal is the only thing that title may ever describe. */
export interface IProbeNotice {
  title: string;
  message: string;
}

export function capRefusalNotice(result: IProbeResult): IProbeNotice {
  return { title: 'Too large to download', message: capMessage(result) };
}

export function probeFailureNotice(err: Error): IProbeNotice {
  return { title: 'Could not check that folder', message: err.message };
}

/** Replaces the node at `path` (a folder prefix) inside the tree, without mutating. */
function updateFolder(nodes: ITreeNode[], path: string, change: (node: ITreeNode) => ITreeNode): ITreeNode[] {
  return nodes.map((node) => {
    if (node.path === path) { return change(node); }
    if (node.children) { return { ...node, children: updateFolder(node.children, path, change) }; }
    return node;
  });
}

/**
 * Claims `path` for an in-flight probe, mutating `inFlight` in place. Returns
 * false — without adding anything — when a probe for this path is already
 * running, so the caller can bail out before ever calling `probe()` or touching
 * React state. Backed by a ref (not state) because a ref reads synchronously
 * within the same click handler, even before React has re-rendered the button
 * that would otherwise be the only thing stopping a second click.
 */
export function claimProbe(inFlight: Set<string>, path: string): boolean {
  if (inFlight.has(path)) { return false; }
  inFlight.add(path);
  return true;
}

/**
 * Whether the root-paging effect should fetch the next page. A continuation
 * that has already failed for this exact cursor must not be retried just
 * because `loading` flipped back to false — that flip is what a failure does,
 * so retrying on it alone reissues the same failing request forever.
 */
export function shouldContinuePaging(
  cursor: string | undefined,
  failedCursor: string | undefined,
  loading: boolean
): boolean {
  return !!cursor && cursor !== failedCursor && !loading;
}

export const FileTree: React.FC<IFileTreeProps> = (props) => {
  const { service, width, selectedPath, onSelectMessage, onDownloadFile } = props;

  const [roots, setRoots] = React.useState<ITreeNode[]>([]);
  const [rootCursor, setRootCursor] = React.useState<string | undefined>(undefined);
  // The cursor a root-page fetch last failed on. Distinct from `error` (which is
  // just display text) because the continuation effect needs to compare against
  // the exact cursor it would otherwise retry — see shouldContinuePaging.
  const [failedRootCursor, setFailedRootCursor] = React.useState<string | undefined>(undefined);
  const [filter, setFilter] = React.useState('');
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | undefined>(undefined);
  // Either a real cap refusal or a probe that failed outright (auth, network, throttling).
  // Kept as one state slot with its own title per outcome — see IProbeNotice — rather
  // than two booleans, so the dialog can never show one outcome's title over the other's
  // message.
  const [notice, setNotice] = React.useState<IProbeNotice | undefined>(undefined);
  // Per-folder probe-in-flight state, keyed by folder path. A plain Set (not global
  // boolean) so probing one folder never disables another row's download control.
  const [probing, setProbing] = React.useState<ReadonlySet<string>>(new Set());
  // Mirrors `probing` synchronously. React state updates aren't visible until the
  // next render, so a second click arriving before that render (same batch) would
  // read stale state and re-enter; the ref is readable immediately.
  const probingRef = React.useRef<Set<string>>(new Set());

  // Root level: 1,000 per page, so all 1,519 matters arrive in two calls.
  const loadRoots = React.useCallback((cursor?: string): void => {
    setLoading(true);
    service.list('', cursor)
      .then((page) => {
        setRoots((prev) => prev.concat(page.folders).concat(page.files));
        setRootCursor(page.cursor);
        setFailedRootCursor(undefined);
        setError(undefined);
        setLoading(false);
      })
      .catch((err: Error) => {
        setError(err.message);
        setFailedRootCursor(cursor);
        setLoading(false);
      });
  }, [service]);

  React.useEffect(() => { loadRoots(); }, [loadRoots]);

  // Keep fetching root pages until the container root is complete; the filter box
  // is only honest once every matter is in hand. Stops once a cursor has already
  // failed, rather than reissuing the same failing request on every render.
  React.useEffect(() => {
    if (shouldContinuePaging(rootCursor, failedRootCursor, loading)) { loadRoots(rootCursor); }
  }, [rootCursor, failedRootCursor, loading, loadRoots]);

  // A deliberate retry of the page that failed — the only way that cursor is
  // fetched again once shouldContinuePaging has stopped the automatic effect.
  const retryRoots = React.useCallback((): void => { loadRoots(failedRootCursor); }, [loadRoots, failedRootCursor]);

  const loadChildren = React.useCallback((node: ITreeNode, cursor?: string): void => {
    setRoots((prev) => updateFolder(prev, node.path, (n) => ({ ...n, loading: true })));
    service.list(node.path, cursor)
      .then((page) => {
        setRoots((prev) => updateFolder(prev, node.path, (n) => ({
          ...n,
          loading: false,
          expanded: true,
          error: undefined, // a successful fetch supersedes any earlier failure
          children: (n.children || []).concat(page.folders).concat(page.files),
          cursor: page.cursor
        })));
      })
      .catch((err: Error) => {
        setRoots((prev) => updateFolder(prev, node.path, (n) => ({ ...n, loading: false, error: err.message })));
      });
  }, [service]);

  const toggleFolder = React.useCallback((node: ITreeNode): void => {
    if (!node.expanded && !node.children) { loadChildren(node); return; }
    setRoots((prev) => updateFolder(prev, node.path, (n) => ({ ...n, expanded: !n.expanded })));
  }, [loadChildren]);

  // Probe before navigating: a navigation answered with 413 shows the user nothing.
  // A real probe against the archive runs 8-12s on a large folder, so the control
  // shows a per-folder pending state while it is in flight — otherwise a click on
  // exactly the folders where the refusal dialog matters looks like nothing happened.
  const downloadFolder = React.useCallback((node: ITreeNode): void => {
    // Bail before touching state or calling probe() — the ref is what actually
    // stops re-entry; the visible spinner swap is just its side effect on the
    // next render, not the guard itself.
    if (!claimProbe(probingRef.current, node.path)) { return; }

    setProbing((prev) => {
      const next = new Set(prev);
      next.add(node.path);
      return next;
    });

    const clearProbing = (): void => {
      probingRef.current.delete(node.path);
      setProbing((prev) => {
        if (!prev.has(node.path)) { return prev; }
        const next = new Set(prev);
        next.delete(node.path);
        return next;
      });
    };

    service.probe(node.path)
      .then((result) => {
        if (!result.withinLimit) { setNotice(capRefusalNotice(result)); clearProbing(); return; }
        window.location.href = service.zipUrl(node.path);
        clearProbing();
      })
      .catch((err: Error) => { setNotice(probeFailureNotice(err)); clearProbing(); });
  }, [service]);

  const visible = React.useMemo(
    () => flattenVisible(filterRoots(roots, filter)),
    [roots, filter]
  );

  const renderRow = (row?: ITreeRow): JSX.Element | null => {
    if (!row) { return null; }
    const { node, depth, kind } = row;
    const indent = { paddingLeft: 8 + depth * 16 };

    if (kind === 'more') {
      return (
        <div className={styles.treeMore} style={indent} onClick={() => loadChildren(node, node.cursor)}>
          {node.loading ? <Spinner size={SpinnerSize.xSmall} /> : `Load more — ${(node.children || []).length} shown so far`}
        </div>
      );
    }

    const isFolder = kind === 'folder';
    const isProbing = isFolder && probing.has(node.path);
    // Both the first expand and a 'load more' continuation set node.loading, so
    // the row itself — not just the synthetic 'more' row — shows it is busy.
    const isLoadingChildren = isFolder && node.loading === true;
    const hasChildError = isFolder && !isLoadingChildren && !!node.error;
    const onRowClick = (): void => {
      if (isFolder) { toggleFolder(node); }
      else if (kind === 'eml' || kind === 'msg') { onSelectMessage(node.path, node.name); }
      else { onDownloadFile(node.path); }
    };

    return (
      <div
        className={node.path === selectedPath ? `${styles.treeRow} ${styles.treeRowSelected}` : styles.treeRow}
        style={indent}
        onClick={onRowClick}
        onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); onRowClick(); } }}
        role="listitem"
        tabIndex={0}
        aria-expanded={isFolder ? node.expanded === true : undefined}
      >
        {isFolder
          ? (isLoadingChildren
            ? <Spinner className={styles.treeChevron} size={SpinnerSize.xSmall} />
            : (
              <Icon
                className={styles.treeChevron}
                iconName={hasChildError ? 'Warning' : (node.expanded ? 'ChevronDown' : 'ChevronRight')}
                style={hasChildError ? { color: '#a4262c' } : undefined}
                title={hasChildError ? node.error : undefined}
              />
            ))
          : <span className={styles.treeChevron} />}
        <Icon
          className={styles.treeIcon}
          iconName={isFolder ? 'FabricFolder' : fileTypeIcon(node.name)}
          style={{ color: isFolder ? '#c19c00' : fileTypeColor(node.name) }}
        />
        <span className={styles.treeName} title={node.name}>{node.name}</span>
        {!isFolder && <span className={styles.treeSize}>{formatSize(node.sizeBytes || 0)}</span>}
        {isProbing
          ? <Spinner className={styles.treeDownload} size={SpinnerSize.xSmall} />
          : (
            <IconButton
              className={styles.treeDownload}
              iconProps={{ iconName: 'Download' }}
              title={isFolder ? `Download ${node.name} as a zip, attachments included` : `Download ${node.name}`}
              ariaLabel={isFolder ? `Download folder ${node.name}` : `Download ${node.name}`}
              onClick={(e) => {
                e.stopPropagation();   // the row click would preview or expand instead
                if (isFolder) { downloadFolder(node); } else { onDownloadFile(node.path); }
              }}
            />
          )}
      </div>
    );
  };

  return (
    <div className={styles.treePane} style={{ flex: `0 0 ${width}px` }}>
      <SearchBox
        className={styles.treeFilter}
        placeholder="Filter matters"
        value={filter}
        onChange={(_, value) => setFilter(value || '')}
        onClear={() => setFilter('')}
      />

      {error && (
        <MessageBar
          messageBarType={MessageBarType.error}
          actions={<MessageBarButton onClick={retryRoots}>Retry</MessageBarButton>}
        >
          {error}
        </MessageBar>
      )}

      {/* role="list"/"listitem", not "tree"/"treeitem": Fluent's List inserts its own
          ms-List / ms-List-page wrapper divs between this container and each row, which
          breaks the ARIA tree parent/child relationship regardless of what the rows
          themselves carry. list/listitem tolerates the intervening wrappers - the same
          pattern EmailList already uses successfully - while aria-expanded on folder
          rows still says what a treeitem's would. */}
      <div className={styles.treeRows} role="list">
        {loading && roots.length === 0
          ? <Spinner size={SpinnerSize.medium} label="Loading matters…" />
          : <List items={visible} onRenderCell={renderRow} />}
      </div>

      <Dialog
        hidden={!notice}
        onDismiss={() => setNotice(undefined)}
        dialogContentProps={{ type: DialogType.normal, title: notice ? notice.title : '' }}
      >
        {notice ? notice.message : ''}
        <DialogFooter>
          <PrimaryButton onClick={() => setNotice(undefined)} text="OK" />
        </DialogFooter>
      </Dialog>
    </div>
  );
};
