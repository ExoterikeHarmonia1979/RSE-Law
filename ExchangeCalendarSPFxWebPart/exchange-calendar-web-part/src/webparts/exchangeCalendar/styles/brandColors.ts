// Keep in sync with ./_brandColors.scss - duplicated because Sass variables and TS constants can't share a source.
export const rseNavy = '#16324a';
export const rseNavyDark = '#0b1e30';
export const rseGold = '#b8935a';
export const rseGoldLight = '#c7a877';
export const rseGoldDark = '#a3814c';
export const rseCream = '#ede7da';

// Rotating per-event background palette (dark tones, all pass WCAG AA contrast with white text)
// so adjacent events are easy to tell apart. Assign by each event's index within its day.
const eventPalette = ['#16324a', '#2c4a52', '#6b2d3c', '#33513f', '#7a5e33'];

export function getEventColor(indexInDay: number): string {
  return eventPalette[indexInDay % eventPalette.length];
}
