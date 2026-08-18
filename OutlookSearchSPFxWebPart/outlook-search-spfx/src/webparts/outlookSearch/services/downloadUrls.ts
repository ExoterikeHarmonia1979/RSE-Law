/**
 * URLs for downloading an archived message or one of its attachments.
 *
 * Everything goes through EmlPreviewFunc. That function holds the storage
 * credential, so the browser never addresses the blob container directly and no
 * storage key or SAS is ever handed to the page. `emlPreviewUrl` already carries
 * the function key (?code=...), which is why these append with '&'.
 */

/** The original .eml, served as a download. */
export function emlDownloadUrl(emlPreviewUrl: string, storagePath: string): string {
  return `${emlPreviewUrl}&path=${encodeURIComponent(storagePath)}`;
}

/**
 * One attachment. `download` picks the Content-Disposition: false opens a PDF or
 * image in a new tab, true always saves it. Opening is the better default for
 * reading, saving the better one for an explicit download control.
 */
export function attachmentUrl(
  emlPreviewUrl: string,
  storagePath: string,
  attachmentName: string,
  download: boolean
): string {
  const url =
    `${emlPreviewUrl}&path=${encodeURIComponent(storagePath)}` +
    `&att=${encodeURIComponent(attachmentName)}`;
  return download ? `${url}&dl=1` : url;
}
