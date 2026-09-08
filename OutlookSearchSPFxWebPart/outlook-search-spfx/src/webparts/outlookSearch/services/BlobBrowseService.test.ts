import { BlobBrowseService } from './BlobBrowseService';

const BASE = 'https://fn.azurewebsites.net/api/MattersBrowseFunc?code=abc123';

function fakeHttp(payload: unknown, ok = true, status = 200): { get: jest.Mock } {
  return {
    get: jest.fn().mockResolvedValue({
      ok,
      status,
      json: () => Promise.resolve(payload)
    })
  };
}

describe('BlobBrowseService', () => {
  it('builds a zip url that appends to the existing function key', () => {
    const service = new BlobBrowseService(fakeHttp({}) as never, BASE);

    expect(service.zipUrl('120.057/')).toBe(`${BASE}&op=zip&prefix=120.057%2F`);
  });

  it('requests one level and maps folders and files into nodes', async () => {
    const http = fakeHttp({
      prefix: '120.057/',
      folders: [{ name: 'Emails', path: '120.057/Emails/' }],
      files: [{
        name: 'a.eml',
        path: 'https://samatters.blob.core.windows.net/matters/120.057/a.eml',
        sizeBytes: 12,
        lastModified: '2025-03-04T17:33:58.0000000+00:00',
        kind: 'eml'
      }],
      cursor: null
    });
    const service = new BlobBrowseService(http as never, BASE);

    const page = await service.list('120.057/');

    expect(http.get).toHaveBeenCalledWith(
      `${BASE}&op=list&prefix=120.057%2F`,
      expect.anything()
    );
    expect(page.folders[0]).toEqual(
      expect.objectContaining({ name: 'Emails', path: '120.057/Emails/', kind: 'folder', expanded: false })
    );
    expect(page.files[0]).toEqual(expect.objectContaining({ name: 'a.eml', kind: 'eml', sizeBytes: 12 }));
    expect(page.cursor).toBeUndefined();
  });

  it('passes a cursor through when continuing a folder', async () => {
    const http = fakeHttp({ prefix: '', folders: [], files: [], cursor: 'next-token' });
    const service = new BlobBrowseService(http as never, BASE);

    const page = await service.list('', 'abc');

    expect(http.get).toHaveBeenCalledWith(
      `${BASE}&op=list&prefix=&cursor=abc`,
      expect.anything()
    );
    expect(page.cursor).toBe('next-token');
  });

  it('throws with the status when listing fails', async () => {
    const service = new BlobBrowseService(fakeHttp({}, false, 502) as never, BASE);

    await expect(service.list('120.057/')).rejects.toThrow('HTTP 502');
  });

  it('reads a probe result', async () => {
    const http = fakeHttp({ files: 2001, bytes: 5, withinLimit: false, fileLimit: 2000, byteLimit: 10 });
    const service = new BlobBrowseService(http as never, BASE);

    const result = await service.probe('Unsorted/');

    expect(result.withinLimit).toBe(false);
    expect(result.files).toBe(2001);
  });

  it('degrades a folder entry missing a path rather than throwing', async () => {
    const http = fakeHttp({ prefix: '120.057/', folders: [{ name: 'Emails' }], files: [], cursor: null });
    const service = new BlobBrowseService(http as never, BASE);

    const page = await service.list('120.057/');

    expect(page.folders[0]).toEqual(
      expect.objectContaining({ name: 'Emails', path: '', kind: 'folder', expanded: false })
    );
  });

  it('falls back to "other" for an unrecognized or non-string file kind', async () => {
    const http = fakeHttp({
      prefix: '120.057/',
      folders: [],
      files: [
        { name: 'weird.xyz', path: 'https://samatters.blob.core.windows.net/matters/weird.xyz', kind: 'spreadsheet' },
        { name: 'no-kind', path: 'https://samatters.blob.core.windows.net/matters/no-kind', kind: 42 }
      ],
      cursor: null
    });
    const service = new BlobBrowseService(http as never, BASE);

    const page = await service.list('120.057/');

    expect(page.files[0].kind).toBe('other');
    expect(page.files[1].kind).toBe('other');
  });

  it('treats a non-numeric sizeBytes as 0 rather than NaN', async () => {
    const http = fakeHttp({
      prefix: '120.057/',
      folders: [],
      files: [{
        name: 'a.eml',
        path: 'https://samatters.blob.core.windows.net/matters/a.eml',
        sizeBytes: 'not-a-number',
        kind: 'eml'
      }],
      cursor: null
    });
    const service = new BlobBrowseService(http as never, BASE);

    const page = await service.list('120.057/');

    expect(page.files[0].sizeBytes).toBe(0);
  });
});
