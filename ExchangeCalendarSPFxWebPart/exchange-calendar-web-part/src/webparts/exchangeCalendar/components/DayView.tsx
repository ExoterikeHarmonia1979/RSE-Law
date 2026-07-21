import * as React from 'react';
import styles from './DayView.module.scss';
import type { ICalendarEvent } from '../models/ICalendarEvent';
import { clampEventToWindow, isSameDay } from '../utils/dateUtils';
import { layoutTimedEvents } from '../utils/eventLayout';
import { getEventColor } from '../styles/brandColors';

export interface IDayViewProps {
  currentDate: Date;
  events: ICalendarEvent[];
  onEventClick: (event: ICalendarEvent) => void;
}

const START_HOUR = 8;
const END_HOUR = 17;
const HOURS = Array.from({ length: END_HOUR - START_HOUR }, (_unused, i) => START_HOUR + i);
const HOUR_HEIGHT = 56;
const MIN_EVENT_HEIGHT = 20;
const MIN_HEIGHT_FOR_TIME_LINE = 36;

function formatHour(hour: number): string {
  return new Date(2000, 0, 1, hour).toLocaleTimeString(undefined, { hour: 'numeric' });
}

function formatTimeRange(event: ICalendarEvent): string {
  const opts: Intl.DateTimeFormatOptions = { hour: 'numeric', minute: '2-digit' };
  return `${event.start.toLocaleTimeString(undefined, opts)} - ${event.end.toLocaleTimeString(undefined, opts)}`;
}

const DayView: React.FunctionComponent<IDayViewProps> = ({ currentDate, events, onEventClick }) => {
  const dayEvents = events
    .filter((e) => isSameDay(e.start, currentDate))
    .sort((a, b) => a.start.getTime() - b.start.getTime());
  const allDayEvents = dayEvents.filter((e) => e.isAllDay);
  const windowStart = new Date(currentDate.getFullYear(), currentDate.getMonth(), currentDate.getDate(), START_HOUR, 0, 0, 0);
  const windowEnd = new Date(currentDate.getFullYear(), currentDate.getMonth(), currentDate.getDate(), END_HOUR, 0, 0, 0);
  const timedEvents = dayEvents
    .filter((e) => !e.isAllDay)
    .map((e) => clampEventToWindow(e, windowStart, windowEnd))
    .filter((e): e is ICalendarEvent => !!e);

  return (
    <div className={styles.dayView}>
      {allDayEvents.length > 0 && (
        <div className={styles.allDayRow}>
          {allDayEvents.map((event, index) => (
            <button
              key={event.id}
              type="button"
              className={styles.eventChip}
              style={{ backgroundColor: getEventColor(index) }}
              onClick={() => onEventClick(event)}
            >
              {event.subject}
            </button>
          ))}
        </div>
      )}

      <div className={styles.timeGrid}>
        <div className={styles.timeGutterColumn}>
          {HOURS.map((hour) => (
            <div key={hour} className={styles.hourLabel} style={{ height: HOUR_HEIGHT }}>{formatHour(hour)}</div>
          ))}
        </div>
        <div className={styles.dayColumn} style={{ height: HOUR_HEIGHT * HOURS.length }}>
          {HOURS.map((hour) => (
            <div key={hour} className={styles.hourCell} style={{ height: HOUR_HEIGHT }} />
          ))}
          {layoutTimedEvents(timedEvents).map(({ event, column, columnCount }, index) => {
            const startMinutes = (event.start.getHours() - START_HOUR) * 60 + event.start.getMinutes();
            const durationMinutes = (event.end.getTime() - event.start.getTime()) / 60000;
            const widthPercent = 100 / columnCount;
            const heightPx = Math.max((durationMinutes / 60) * HOUR_HEIGHT, MIN_EVENT_HEIGHT);
            const canShowTimeLine = heightPx >= MIN_HEIGHT_FOR_TIME_LINE;
            return (
              <button
                key={event.id}
                type="button"
                className={styles.timedEvent}
                style={{
                  top: (startMinutes / 60) * HOUR_HEIGHT,
                  height: heightPx,
                  left: `${column * widthPercent}%`,
                  width: `calc(${widthPercent}% - 4px)`,
                  backgroundColor: getEventColor(index)
                }}
                onClick={() => onEventClick(event)}
                title={`${event.subject} (${formatTimeRange(event)})`}
              >
                <div className={styles.eventSubject}>{event.subject}</div>
                {canShowTimeLine && <div className={styles.eventTime}>{formatTimeRange(event)}</div>}
              </button>
            );
          })}
        </div>
      </div>
    </div>
  );
};

export default DayView;
