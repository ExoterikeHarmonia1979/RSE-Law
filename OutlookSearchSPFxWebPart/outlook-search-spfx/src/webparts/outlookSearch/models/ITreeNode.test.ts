import { ITreeNode, flattenVisible, filterRoots } from './ITreeNode';

function folder(name: string, extra?: Partial<ITreeNode>): ITreeNode {
  return { name, path: `${name}/`, kind: 'folder', expanded: false, ...extra };
}

function file(name: string): ITreeNode {
  return { name, path: `https://samatters.blob.core.windows.net/matters/${name}`, kind: 'eml' };
}

describe('flattenVisible', () => {
  it('shows only the roots when nothing is expanded', () => {
    const rows = flattenVisible([folder('120.057'), folder('95A.002')]);

    expect(rows.map((r) => r.node.name)).toEqual(['120.057', '95A.002']);
    expect(rows.every((r) => r.depth === 0)).toBe(true);
  });

  it('includes the children of an expanded folder, one level deeper', () => {
    const rows = flattenVisible([
      folder('120.057', { expanded: true, children: [folder('Emails'), file('note.eml')] })
    ]);

    expect(rows.map((r) => r.node.name)).toEqual(['120.057', 'Emails', 'note.eml']);
    expect(rows.map((r) => r.depth)).toEqual([0, 1, 1]);
  });

  it('hides the children of a collapsed folder that has already loaded them', () => {
    const rows = flattenVisible([
      folder('120.057', { expanded: false, children: [file('note.eml')] })
    ]);

    expect(rows).toHaveLength(1);
  });

  it('appends a "more" row when the folder has a cursor left', () => {
    const rows = flattenVisible([
      folder('Unsorted', { expanded: true, children: [file('a.eml')], cursor: 'abc' })
    ]);

    expect(rows[rows.length - 1].kind).toBe('more');
    expect(rows[rows.length - 1].depth).toBe(1);
  });

  it('does not append a "more" row to a fully loaded folder', () => {
    const rows = flattenVisible([
      folder('120.057', { expanded: true, children: [file('a.eml')] })
    ]);

    expect(rows.some((r) => r.kind === 'more')).toBe(false);
  });

  it('recurses through nested expansions', () => {
    const rows = flattenVisible([
      folder('120.057', {
        expanded: true,
        children: [folder('Emails', { expanded: true, children: [file('a.eml')] })]
      })
    ]);

    expect(rows.map((r) => r.depth)).toEqual([0, 1, 2]);
  });

  it('places a "more" row after an inner folder\'s children, at the inner folder\'s depth, while the outer folder (no cursor) gets none of its own', () => {
    const rows = flattenVisible([
      folder('120.057', {
        expanded: true,
        children: [
          folder('Emails', { expanded: true, children: [file('a.eml')], cursor: 'inner-token' })
        ]
      })
    ]);

    expect(rows.map((r) => r.node.name)).toEqual(['120.057', 'Emails', 'a.eml', 'Emails']);
    expect(rows.map((r) => r.kind)).toEqual(['folder', 'folder', 'eml', 'more']);
    expect(rows.map((r) => r.depth)).toEqual([0, 1, 2, 2]);
    expect(rows.filter((r) => r.kind === 'more')).toHaveLength(1);
  });
});

describe('filterRoots', () => {
  const roots = [folder('120.057'), folder('120.027'), folder('95A.002')];

  it('returns everything for an empty filter', () => {
    expect(filterRoots(roots, '')).toHaveLength(3);
  });

  it('matches a substring anywhere in the name', () => {
    expect(filterRoots(roots, '120.').map((n) => n.name)).toEqual(['120.057', '120.027']);
  });

  it('ignores case', () => {
    expect(filterRoots(roots, '95a').map((n) => n.name)).toEqual(['95A.002']);
  });
});
