import * as React from 'react';
import { List, Icon, IconButton, SearchBox, Spinner, SpinnerSize, MessageBar, MessageBarType, Dialog, DialogType, DialogFooter, PrimaryButton } from '@fluentui/react';
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

/** Replaces the node at `path` (a folder prefix) inside the tree, without mutating. */
function updateFolder(nodes: ITreeNode[], path: string, change: (node: ITreeNode) => ITreeNode): ITreeNode[] {
  return nodes.map((node) => {
    if (node.path === path) { return change(node); }
    if (node.children) { return { ...node, children: updateFolder(node.children, path, change) }; }
    return node;
  });
}

export const FileTree: React.FC<IFileTreeProps> = (props) => {
  const { service, width, selectedPath, onSelectMessage, onDownloadFile } = props;

  const [roots, setRoots] = React.useState<ITreeNode[]>([]);
  const [rootCursor, setRootCursor] = React.useState<string | undefined>(undefined);
  const [filter, setFilter] = React.useState('');
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | undefined>(undefined);
  const [refusal, setRefusal] = React.useState<string | undefined>(undefined);
  // Per-folder probe-in-flight state, keyed by folder path. A plain Set (not global
  // boolean) so probing one folder never disables another row's download control.
  const [probing, setProbing] = React.useState<ReadonlySet<string>>(new Set());

  // Root level: 1,000 per page, so all 1,519 matters arrive in two calls.
  const loadRoots = React.useCallback((cursor?: string): void => {
    setLoading(true);
    service.list('', cursor)
      .then((page) => {
        setRoots((prev) => prev.concat(page.folders).concat(page.files));
        setRootCursor(page.cursor);
        setLoading(false);
      })
      .catch((err: Error) => { setError(err.message); setLoading(false); });
  }, [service]);

  React.useEffect(() => { loadRoots(); }, [loadRoots]);

  // Keep fetching root pages until the container root is complete; the filter box
  // is only honest once every matter is in hand.
  React.useEffect(() => {
    if (rootCursor && !loading) { loadRoots(rootCursor); }
  }, [rootCursor, loading, loadRoots]);

  const loadChildren = React.useCallback((node: ITreeNode, cursor?: string): void => {
    setRoots((prev) => updateFolder(prev, node.path, (n) => ({ ...n, loading: true })));
    service.list(node.path, cursor)
      .then((page) => {
        setRoots((prev) => updateFolder(prev, node.path, (n) => ({
          ...n,
          loading: false,
          expanded: true,
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
    setProbing((prev) => {
      if (prev.has(node.path)) { return prev; } // already probing this folder — ignore the re-click
      const next = new Set(prev);
      next.add(node.path);
      return next;
    });

    const clearProbing = (): void => {
      setProbing((prev) => {
        if (!prev.has(node.path)) { return prev; }
        const next = new Set(prev);
        next.delete(node.path);
        return next;
      });
    };

    service.probe(node.path)
      .then((result) => {
        if (!result.withinLimit) { setRefusal(capMessage(result)); clearProbing(); return; }
        window.location.href = service.zipUrl(node.path);
        clearProbing();
      })
      .catch((err: Error) => { setRefusal(err.message); clearProbing(); });
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
        role="treeitem"
        aria-expanded={isFolder ? node.expanded === true : undefined}
      >
        {isFolder
          ? <Icon className={styles.treeChevron} iconName={node.expanded ? 'ChevronDown' : 'ChevronRight'} />
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

      {error && <MessageBar messageBarType={MessageBarType.error}>{error}</MessageBar>}

      <div className={styles.treeRows} role="tree">
        {loading && roots.length === 0
          ? <Spinner size={SpinnerSize.medium} label="Loading matters…" />
          : <List items={visible} onRenderCell={renderRow} />}
      </div>

      <Dialog
        hidden={!refusal}
        onDismiss={() => setRefusal(undefined)}
        dialogContentProps={{ type: DialogType.normal, title: 'Too large to download' }}
      >
        {refusal}
        <DialogFooter>
          <PrimaryButton onClick={() => setRefusal(undefined)} text="OK" />
        </DialogFooter>
      </Dialog>
    </div>
  );
};
