import type { MSGraphClientV3 } from '@microsoft/sp-http';
import type { ICalendarEvent } from '../models/ICalendarEvent';

interface IGraphEvent {
  id: string;
  subject: string;
  start: { dateTime: string };
  end: { dateTime: string };
  isAllDay: boolean;
  location?: { displayName: string };
  organizer?: { emailAddress?: { name: string } };
  bodyPreview?: string;
}

interface IGraphCalendarViewResponse {
  value: IGraphEvent[];
  '@odata.nextLink'?: string;
}

function parseUtcDateTime(dateTime: string): Date {
  return new Date(dateTime.endsWith('Z') ? dateTime : `${dateTime}Z`);
}

function mapEvent(event: IGraphEvent): ICalendarEvent {
  return {
    id: event.id,
    subject: event.subject?.trim() || '(No subject)',
    start: parseUtcDateTime(event.start.dateTime),
    end: parseUtcDateTime(event.end.dateTime),
    isAllDay: event.isAllDay,
    location: event.location?.displayName || '',
    organizerName: event.organizer?.emailAddress?.name || '',
    bodyPreview: event.bodyPreview || ''
  };
}

/** Fetches all events in [start, end] for the given calendar, following @odata.nextLink pagination. */
export async function getCalendarEvents(
  client: MSGraphClientV3,
  calendarEmail: string,
  start: Date,
  end: Date
): Promise<ICalendarEvent[]> {
  const events: ICalendarEvent[] = [];

  let response: IGraphCalendarViewResponse = await client
    .api(`/users/${encodeURIComponent(calendarEmail)}/calendarView`)
    .header('Prefer', 'outlook.timezone="UTC"')
    .query({ startDateTime: start.toISOString(), endDateTime: end.toISOString() })
    .orderby('start/dateTime')
    .top(100)
    .get();

  events.push(...response.value.map(mapEvent));

  while (response['@odata.nextLink']) {
    response = await client.api(response['@odata.nextLink']).get();
    events.push(...response.value.map(mapEvent));
  }

  // Graph can return the same occurrence twice at pagination/recurrence boundaries; de-dupe by id
  // so the calendar UI never lays out two identical events as if they were distinct overlapping ones.
  return Array.from(new Map(events.map((event) => [event.id, event])).values());
}
