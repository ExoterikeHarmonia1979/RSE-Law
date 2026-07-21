import type { ICalendarEvent } from '../models/ICalendarEvent';

export interface IPositionedEvent {
  event: ICalendarEvent;
  column: number;
  columnCount: number;
}

/**
 * Assigns each event a column and the total column count of its overlap cluster, so
 * concurrent events render side-by-side instead of one fully covering another.
 */
export function layoutTimedEvents(events: ICalendarEvent[]): IPositionedEvent[] {
  const sorted = [...events].sort(
    (a, b) => a.start.getTime() - b.start.getTime() || a.end.getTime() - b.end.getTime()
  );

  const clusters: ICalendarEvent[][] = [];
  let currentCluster: ICalendarEvent[] = [];
  let clusterEnd = -Infinity;

  sorted.forEach((event) => {
    if (currentCluster.length === 0 || event.start.getTime() < clusterEnd) {
      currentCluster.push(event);
      clusterEnd = Math.max(clusterEnd, event.end.getTime());
    } else {
      clusters.push(currentCluster);
      currentCluster = [event];
      clusterEnd = event.end.getTime();
    }
  });
  if (currentCluster.length > 0) {
    clusters.push(currentCluster);
  }

  const result: IPositionedEvent[] = [];

  clusters.forEach((cluster) => {
    const columns: ICalendarEvent[][] = [];
    const eventColumn = new Map<string, number>();

    cluster.forEach((event) => {
      let placedColumn = -1;
      for (let i = 0; i < columns.length; i++) {
        const lastInColumn = columns[i][columns[i].length - 1];
        if (event.start.getTime() >= lastInColumn.end.getTime()) {
          columns[i].push(event);
          placedColumn = i;
          break;
        }
      }
      if (placedColumn === -1) {
        columns.push([event]);
        placedColumn = columns.length - 1;
      }
      eventColumn.set(event.id, placedColumn);
    });

    const columnCount = columns.length;
    cluster.forEach((event) => {
      result.push({ event, column: eventColumn.get(event.id) as number, columnCount });
    });
  });

  return result;
}
