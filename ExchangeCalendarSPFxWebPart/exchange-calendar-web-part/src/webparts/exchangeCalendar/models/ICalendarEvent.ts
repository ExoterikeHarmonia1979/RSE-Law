export interface ICalendarEvent {
  id: string;
  subject: string;
  start: Date;
  end: Date;
  isAllDay: boolean;
  location: string;
  organizerName: string;
  bodyPreview: string;
}
