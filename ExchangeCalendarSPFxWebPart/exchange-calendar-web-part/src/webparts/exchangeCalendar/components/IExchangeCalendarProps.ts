import type { MSGraphClientFactory } from '@microsoft/sp-http';
import type { CalendarView } from '../models/CalendarView';

export interface IExchangeCalendarProps {
  calendarEmail: string;
  defaultView: CalendarView;
  graphClientFactory: MSGraphClientFactory;
}
