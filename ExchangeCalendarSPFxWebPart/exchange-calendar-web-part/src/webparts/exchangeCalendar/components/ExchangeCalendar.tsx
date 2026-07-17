import * as React from 'react';
import { useCallback, useEffect, useState } from 'react';
import { DefaultButton, IconButton, MessageBar, MessageBarType, Pivot, PivotItem, Spinner, SpinnerSize, Stack, Text } from '@fluentui/react';
import styles from './ExchangeCalendar.module.scss';
import type { IExchangeCalendarProps } from './IExchangeCalendarProps';
import { CalendarView } from '../models/CalendarView';
import type { ICalendarEvent } from '../models/ICalendarEvent';
import { getCalendarEvents } from '../services/GraphCalendarService';
import { getRangeForView, getRangeLabel, navigate } from '../utils/dateUtils';
import MonthView from './MonthView';
import WeekView from './WeekView';
import DayView from './DayView';
import EventDetailsPanel from './EventDetailsPanel';

const ExchangeCalendar: React.FunctionComponent<IExchangeCalendarProps> = (props) => {
  const { calendarEmail, defaultView, graphClientFactory } = props;

  const [view, setView] = useState<CalendarView>(defaultView);
  const [currentDate, setCurrentDate] = useState<Date>(new Date());
  const [events, setEvents] = useState<ICalendarEvent[]>([]);
  const [loading, setLoading] = useState<boolean>(true);
  const [error, setError] = useState<string | undefined>(undefined);
  const [selectedEvent, setSelectedEvent] = useState<ICalendarEvent | undefined>(undefined);

  const { start, end } = getRangeForView(view, currentDate);
  const startTime = start.getTime();
  const endTime = end.getTime();

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(undefined);

    graphClientFactory
      .getClient('3')
      .then((client) => getCalendarEvents(client, calendarEmail, new Date(startTime), new Date(endTime)))
      .then((result) => {
        if (!cancelled) {
          setEvents(result);
          setLoading(false);
        }
      })
      .catch((err: Error) => {
        if (!cancelled) {
          setError(err.message || `Unable to load events for ${calendarEmail}. Confirm the calendar is shared with you and the Graph API permission has been approved by an admin.`);
          setLoading(false);
        }
      });

    return () => {
      cancelled = true;
    };
  }, [calendarEmail, startTime, endTime, graphClientFactory]);

  const handlePrev = useCallback(() => setCurrentDate((d) => navigate(view, d, -1)), [view]);
  const handleNext = useCallback(() => setCurrentDate((d) => navigate(view, d, 1)), [view]);
  const handleToday = useCallback(() => setCurrentDate(new Date()), []);
  const handleViewChange = useCallback((item?: PivotItem) => {
    if (item?.props.itemKey) {
      setView(item.props.itemKey as CalendarView);
    }
  }, []);
  const handleEventClick = useCallback((event: ICalendarEvent) => setSelectedEvent(event), []);
  const handleDismissDetails = useCallback(() => setSelectedEvent(undefined), []);

  return (
    <div className={styles.exchangeCalendar}>
      <Stack horizontal horizontalAlign="space-between" verticalAlign="center" wrap className={styles.toolbar}>
        <Stack horizontal verticalAlign="center" tokens={{ childrenGap: 8 }}>
          <DefaultButton text="Today" onClick={handleToday} />
          <IconButton iconProps={{ iconName: 'ChevronLeft' }} ariaLabel="Previous" onClick={handlePrev} />
          <IconButton iconProps={{ iconName: 'ChevronRight' }} ariaLabel="Next" onClick={handleNext} />
          <Text variant="xLarge" className={styles.rangeLabel}>{getRangeLabel(view, currentDate)}</Text>
        </Stack>
        <Pivot selectedKey={view} onLinkClick={handleViewChange}>
          <PivotItem headerText="Day" itemKey={CalendarView.Day} />
          <PivotItem headerText="Week" itemKey={CalendarView.Week} />
          <PivotItem headerText="Month" itemKey={CalendarView.Month} />
        </Pivot>
      </Stack>

      {error && (
        <MessageBar messageBarType={MessageBarType.error} className={styles.messageBar}>
          {error}
        </MessageBar>
      )}

      {loading && (
        <Spinner size={SpinnerSize.large} label="Loading calendar events..." className={styles.spinner} />
      )}

      {!loading && !error && view === CalendarView.Month && (
        <MonthView currentDate={currentDate} events={events} onEventClick={handleEventClick} />
      )}
      {!loading && !error && view === CalendarView.Week && (
        <WeekView currentDate={currentDate} events={events} onEventClick={handleEventClick} />
      )}
      {!loading && !error && view === CalendarView.Day && (
        <DayView currentDate={currentDate} events={events} onEventClick={handleEventClick} />
      )}

      <EventDetailsPanel event={selectedEvent} onDismiss={handleDismissDetails} />
    </div>
  );
};

export default ExchangeCalendar;
