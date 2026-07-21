import * as React from 'react';
import { Link } from '@fluentui/react';
import styles from './WeekView.module.scss';
import type { ICalendarEvent } from '../models/ICalendarEvent';
import { addDays, isSameDay, startOfWeek } from '../utils/dateUtils';
import { layoutTimedEvents } from '../utils/eventLayout';
import { getEventColor } from '../styles/brandColors';

export interface IWeekViewProps {
  currentDate: Date;
  events: ICalendarEvent[];
  onEventClick: (event: ICalendarEvent) => void;
}

const HOURS = Array.from({ length: 24 }, (_unused, i) => i);
const HOUR_HEIGHT = 48;
const MIN_EVENT_HEIGHT = 16;
const MAX_VISIBLE_ALL_DAY = 3;

function formatHour(hour: number): string {
  return new Date(2000, 0, 1, hour).toLocaleTimeString(undefined, { hour: 'numeric' });
}

const WeekView: React.FunctionComponent<IWeekViewProps> = ({ currentDate, events, onEventClick }) => {
  const weekStart = startOfWeek(currentDate);
  const weekDays = Array.from({ length: 7 }, (_unused, i) => addDays(weekStart, i));
  const today = new Date();

  return (
    <div className={styles.weekView}>
      <div className={styles.headerRow}>
        <div className={styles.timeGutter} />
        {weekDays.map((day) => (
          <div key={day.toISOString()} className={styles.dayHeader}>
            <div className={styles.dayHeaderWeekday}>{day.toLocaleDateString(undefined, { weekday: 'short' })}</div>
            <div className={isSameDay(day, today) ? styles.todayNumber : styles.dayHeaderNumber}>{day.getDate()}</div>
          </div>
        ))}
      </div>

      <div className={styles.allDayRow}>
        <div className={styles.timeGutter}>All day</div>
        {weekDays.map((day) => {
          const dayAllDayEvents = events.filter((e) => e.isAllDay && isSameDay(e.start, day));
          const visibleEvents = dayAllDayEvents.slice(0, MAX_VISIBLE_ALL_DAY);
          const overflowCount = dayAllDayEvents.length - visibleEvents.length;
          return (
            <div key={day.toISOString()} className={styles.allDayCell}>
              {visibleEvents.map((event, index) => (
                <Link
                  key={event.id}
                  className={styles.eventChip}
                  style={{ backgroundColor: getEventColor(index) }}
                  onClick={() => onEventClick(event)}
                  title={event.subject}
                >
                  {event.subject}
                </Link>
              ))}
              {overflowCount > 0 && <div className={styles.overflow}>+{overflowCount} more</div>}
            </div>
          );
        })}
      </div>

      <div className={styles.timeGrid}>
        <div className={styles.timeGutterColumn}>
          {HOURS.map((hour) => (
            <div key={hour} className={styles.hourLabel} style={{ height: HOUR_HEIGHT }}>{formatHour(hour)}</div>
          ))}
        </div>
        {weekDays.map((day) => (
          <div key={day.toISOString()} className={styles.dayColumn} style={{ height: HOUR_HEIGHT * 24 }}>
            {HOURS.map((hour) => (
              <div key={hour} className={styles.hourCell} style={{ height: HOUR_HEIGHT }} />
            ))}
            {layoutTimedEvents(events.filter((e) => !e.isAllDay && isSameDay(e.start, day))).map(
              ({ event, column, columnCount }, index) => {
                const startMinutes = event.start.getHours() * 60 + event.start.getMinutes();
                const durationMinutes = Math.max((event.end.getTime() - event.start.getTime()) / 60000, 15);
                const widthPercent = 100 / columnCount;
                return (
                  <button
                    key={event.id}
                    type="button"
                    className={styles.timedEvent}
                    style={{
                      top: (startMinutes / 60) * HOUR_HEIGHT,
                      height: Math.max((durationMinutes / 60) * HOUR_HEIGHT, MIN_EVENT_HEIGHT),
                      left: `${column * widthPercent}%`,
                      width: `calc(${widthPercent}% - 2px)`,
                      backgroundColor: getEventColor(index)
                    }}
                    onClick={() => onEventClick(event)}
                    title={event.subject}
                  >
                    {event.subject}
                  </button>
                );
              }
            )}
          </div>
        ))}
      </div>
    </div>
  );
};

export default WeekView;
