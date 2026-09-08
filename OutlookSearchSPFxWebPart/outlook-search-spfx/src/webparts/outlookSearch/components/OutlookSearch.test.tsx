// See FileTree.test.tsx for why the CSS-module SCSS import needs a virtual mock here:
// plain jest (this project's only working test runner — see the task brief) has no
// loader for .scss, and neither test in this file renders JSX, so the class-name
// values themselves are never read.
jest.mock('./OutlookSearch.module.scss', () => ({}), { virtual: true });

import { listWidthForPointer, listPaneAreaWidth, IPaneRect } from './OutlookSearch';

// A regression pin for the tree-pane-width bug: before this fix, onSplitterPointerMove
// used `e.clientX - panesRect.left` as if the list pane always started at the
// container's own left edge. That held before the tree pane existed; once a tree pane
// (280px) plus its splitter (6px) sit in front of the list pane, the same formula was
// off by exactly that much, and the list pane jumped ~286px on the first pointer move.
describe('listWidthForPointer', () => {
  const wideContainer: IPaneRect = { left: 0, width: 1200 };

  it('two-pane case (no tree rendered at all): the list pane starts at the container edge', () => {
    // browseFuncUrl is empty, so listPaneLeft === panesRect.left — offset 0, exactly the
    // pre-tree behaviour.
    const width = listWidthForPointer(500, wideContainer, /* listPaneLeft */ 0);
    expect(width).toBe(500);
  });

  it('three-pane case, tree visible: the list pane starts 286px in, and width tracks the cursor from there', () => {
    // treeWidth 280 + splitter 6 = 286.
    const listPaneLeft = 286;
    const width = listWidthForPointer(600, wideContainer, listPaneLeft);
    // Old (buggy) formula would have returned 600 (clientX - panesRect.left) here,
    // 286px too wide.
    expect(width).toBe(600 - listPaneLeft);
    expect(width).not.toBe(600);
  });

  it('three-pane case, tree visible: dragging to the same clientX as the tree case above never reproduces the two-pane width', () => {
    const twoPane = listWidthForPointer(600, wideContainer, 0);
    const threePane = listWidthForPointer(600, wideContainer, 286);
    expect(threePane).toBe(twoPane - 286);
  });

  it('tree configured but hidden below the 1100px breakpoint: measured DOM geometry — not state — puts the offset back to zero', () => {
    // browseFuncUrl is set (a React-state-only check would think the tree is there),
    // but .treePane and its splitter are display:none, so the list pane's rendered
    // left edge is the container's left edge again. Passing the *measured* listPaneLeft
    // (0, because that's what the DOM actually shows once CSS hides the tree) is what a
    // querySelector('.listPane').getBoundingClientRect() gets right that recomputing
    // from treeWidth would not.
    const width = listWidthForPointer(500, wideContainer, 0);
    expect(width).toBe(500);
  });

  it('clamps against the reading pane minimum within the space actually left after the tree', () => {
    // containerWidth for the clamp is panesRect.width - offset (914), so the max list
    // width here is 914 - 320 (READING_WIDTH_MIN) = 594, not 1200 - 320 = 880.
    const listPaneLeft = 286;
    const width = listWidthForPointer(1500, wideContainer, listPaneLeft);
    expect(width).toBe(594);
  });

  it('clamps to the list pane minimum when dragged far left', () => {
    const width = listWidthForPointer(-500, wideContainer, 0);
    expect(width).toBe(260); // LIST_WIDTH_MIN
  });
});

describe('listPaneAreaWidth', () => {
  it('is the full container width when there is no tree pane in front of the list pane', () => {
    expect(listPaneAreaWidth({ left: 0, width: 1200 }, 0)).toBe(1200);
  });

  it('subtracts exactly what the tree pane and its splitter occupy', () => {
    expect(listPaneAreaWidth({ left: 0, width: 1200 }, 286)).toBe(914);
  });

  it('is unaffected by a nonzero container left (panesRect not flush with the viewport)', () => {
    expect(listPaneAreaWidth({ left: 40, width: 1200 }, 40)).toBe(1200);
    expect(listPaneAreaWidth({ left: 40, width: 1200 }, 40 + 286)).toBe(914);
  });
});
