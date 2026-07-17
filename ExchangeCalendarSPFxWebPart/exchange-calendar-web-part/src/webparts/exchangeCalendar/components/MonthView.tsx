import * as React from 'react';
import { Link } from '@fluentui/react';
import styles from './MonthView.module.scss';
import type { ICalendarEvent } from '../models/ICalendarEvent';
import { getMonthGridDays, isSameDay } from '../utils/dateUtils';
import { getEventColor } from '../styles/brandColors';

export interface IMonthViewProps {
  currentDate: Date;
  events: ICalendarEvent[];
  onEventClick: (event: ICalendarEvent) => void;
}

const WEEKDAY_LABELS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const MAX_VISIBLE_EVENTS = 3;

const MonthView: React.FunctionComponent<IMonthViewProps> = ({ currentDate, events, onEventClick }) => {
  const days = getMonthGridDays(currentDate);
  const today = new Date();

  return (
    <div className={styles.monthView}>
      <div className={styles.weekdayRow}>
        {WEEKDAY_LABELS.map((label) => (
          <div key={label} className={styles.weekdayCell}>{label}</div>
        ))}
      </div>
      <div className={styles.grid}>
        {days.map((day) => {
          const dayEvents = events
            .filter((e) => isSameDay(e.start, day))
            .sort((a, b) => a.start.getTime() - b.start.getTime());
          const visibleEvents = dayEvents.slice(0, MAX_VISIBLE_EVENTS);
          const overflowCount = dayEvents.length - visibleEvents.length;
          const isCurrentMonth = day.getMonth() === currentDate.getMonth();
          const cellClassName = [
            styles.dayCell,
            isCurrentMonth ? '' : styles.outsideMonth,
            isSameDay(day, today) ? styles.today : ''
          ].join(' ').trim();

          return (
            <div key={day.toISOString()} className={cellClassName}>
              <div className={styles.dayNumber}>{day.getDate()}</div>
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
    </div>
  );
};

export default MonthView;
