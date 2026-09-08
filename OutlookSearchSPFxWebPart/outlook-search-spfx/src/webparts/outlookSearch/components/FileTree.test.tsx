// FileTree.tsx (via EmailList.tsx) imports the CSS-module SCSS file. Heft's own
// jest task resolves that through webpack's sass/css loaders, but this project's
// jest task reports "No tests found" regardless of configuration (see the task
// brief), so tests run as plain `jest` over the heft-compiled lib-commonjs output
// instead. Plain jest has no loader for .scss, and heft's build only emits the
// compiled .css (OutlookSearch.module.scss.css) — never a requirable JS module
// named OutlookSearch.module.scss — so the bare import is otherwise unresolvable
// here. This virtual mock stands in for it, exactly as __mocks__/@microsoft/sp-http
// stands in for a package that cannot be required outside a browser host: neither
// test here renders JSX, so the class-name values themselves are never read.
jest.mock('./OutlookSearch.module.scss', () => ({}), { virtual: true });

import { formatSize, capMessage, capRefusalNotice, probeFailureNotice, claimProbe, shouldContinuePaging } from './FileTree';

describe('formatSize', () => {
  it('uses bytes below a kilobyte', () => {
    expect(formatSize(512)).toBe('512 B');
  });

  it('rounds to one decimal in KB and MB', () => {
    expect(formatSize(2048)).toBe('2.0 KB');
    expect(formatSize(5 * 1024 * 1024)).toBe('5.0 MB');
  });

  it('handles a missing size as an empty string', () => {
    expect(formatSize(0)).toBe('');
  });
});

describe('capMessage', () => {
  it('never states a total the walk did not finish', () => {
    const message = capMessage({
      files: 2001, bytes: 0, withinLimit: false, fileLimit: 2000, byteLimit: 2147483648
    });

    expect(message).toContain('more than 2,000 files');
    expect(message).not.toContain('2001');
    expect(message).not.toContain('2,001');
  });

  it('reports a size refusal in gigabytes', () => {
    const message = capMessage({
      files: 10, bytes: 3221225472, withinLimit: false, fileLimit: 2000, byteLimit: 2147483648
    });

    expect(message).toContain('2.0 GB');
  });
});

// A folder that really is too large, and a probe that failed for some other reason
// (an expired function key, a network fault, throttling), must never look the same
// to the user — the dialog is titled from the outcome, not hard-coded to one of them.
describe('capRefusalNotice and probeFailureNotice', () => {
  it('titles a real cap refusal as too large, with the lower-bound message', () => {
    const notice = capRefusalNotice({
      files: 2001, bytes: 0, withinLimit: false, fileLimit: 2000, byteLimit: 2147483648
    });

    expect(notice.title).toBe('Too large to download');
    expect(notice.message).toContain('more than 2,000 files');
  });

  it('titles a probe failure differently from a size refusal, carrying the real error', () => {
    const notice = probeFailureNotice(new Error('Could not check that folder (HTTP 401)'));

    expect(notice.title).not.toBe('Too large to download');
    expect(notice.title).toBe('Could not check that folder');
    expect(notice.message).toBe('Could not check that folder (HTTP 401)');
  });
});

describe('claimProbe', () => {
  it('claims an unheld path and adds it to the set', () => {
    const inFlight = new Set<string>();

    expect(claimProbe(inFlight, 'matters/120.057/')).toBe(true);
    expect(inFlight.has('matters/120.057/')).toBe(true);
  });

  it('refuses a path someone else already holds, and leaves the set untouched', () => {
    const inFlight = new Set<string>(['matters/120.057/']);

    expect(claimProbe(inFlight, 'matters/120.057/')).toBe(false);
    expect(inFlight.size).toBe(1);
  });

  it('does not let one folder\'s claim block a different folder\'s claim', () => {
    const inFlight = new Set<string>(['matters/120.057/']);

    expect(claimProbe(inFlight, 'matters/999.001/')).toBe(true);
    expect(inFlight.has('matters/120.057/')).toBe(true);
    expect(inFlight.has('matters/999.001/')).toBe(true);
  });
});

describe('shouldContinuePaging', () => {
  it('continues when there is a next cursor, it has not failed, and nothing is loading', () => {
    expect(shouldContinuePaging('cursor-2', undefined, false)).toBe(true);
  });

  it('stops when there is no next cursor — the listing is complete', () => {
    expect(shouldContinuePaging(undefined, undefined, false)).toBe(false);
  });

  it('stops while a fetch for it is already in flight', () => {
    expect(shouldContinuePaging('cursor-2', undefined, true)).toBe(false);
  });

  it('stops once this exact cursor has already failed, even after loading clears', () => {
    // This is the unbounded-retry case: a failed continuation flips loading back
    // to false, and without this check the effect would refire on the same cursor
    // forever.
    expect(shouldContinuePaging('cursor-2', 'cursor-2', false)).toBe(false);
  });

  it('resumes once a different, later cursor is current — a past failure does not wedge paging forever', () => {
    expect(shouldContinuePaging('cursor-3', 'cursor-2', false)).toBe(true);
  });
});
