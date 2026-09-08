/** What a row in the file tree can be. 'more' is the synthetic "Load more" row. */
export type TreeRowKind = 'folder' | 'eml' | 'msg' | 'attachment' | 'other' | 'more';

export interface ITreeNode {
  /** Folders: the blob prefix ('120.057/'). Files: the full blob URL, which is what
   *  EmlPreviewFunc accepts as storagePath. */
  path: string;
  name: string;
  kind: Exclude<TreeRowKind, 'more'>;
  sizeBytes?: number;
  lastModified?: string;
  /** Folders only. */
  expanded?: boolean;
  children?: ITreeNode[];
  /** Continuation token from the last list call; set means more children exist. */
  cursor?: string;
  loading?: boolean;
  error?: string;
}

export interface ITreeRow {
  node: ITreeNode;
  depth: number;
  kind: TreeRowKind;
}

export interface IListPage {
  prefix: string;
  folders: ITreeNode[];
  files: ITreeNode[];
  cursor?: string;
}

export interface IProbeResult {
  files: number;
  bytes: number;
  withinLimit: boolean;
  fileLimit: number;
  byteLimit: number;
}

/**
 * The visible rows, in order, for a virtualized list. Children of a collapsed folder
 * stay loaded but unrendered, so collapsing and re-expanding costs no round trip.
 */
export function flattenVisible(nodes: ITreeNode[]): ITreeRow[] {
  const rows: ITreeRow[] = [];

  const walk = (list: ITreeNode[], depth: number): void => {
    for (const node of list) {
      rows.push({ node, depth, kind: node.kind });
      if (node.kind !== 'folder' || !node.expanded) { continue; }
      if (node.children) { walk(node.children, depth + 1); }
      if (node.cursor) {
        rows.push({ node, depth: depth + 1, kind: 'more' });
      }
    }
  };

  walk(nodes, 0);
  return rows;
}

export function filterRoots(nodes: ITreeNode[], filter: string): ITreeNode[] {
  const needle = filter.trim().toLowerCase();
  if (!needle) { return nodes; }
  return nodes.filter((n) => n.name.toLowerCase().indexOf(needle) >= 0);
}
