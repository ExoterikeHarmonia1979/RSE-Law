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

import { formatSize, capMessage } from './FileTree';

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
