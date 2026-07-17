import * as React from 'react';
import { Icon, Panel, PanelType, Stack, Text } from '@fluentui/react';
import type { ICalendarEvent } from '../models/ICalendarEvent';
import styles from './EventDetailsPanel.module.scss';

export interface IEventDetailsPanelProps {
  event: ICalendarEvent | undefined;
  onDismiss: () => void;
}

function formatDateTime(date: Date): string {
  return date.toLocaleString(undefined, { weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
}

const EventDetailsPanel: React.FunctionComponent<IEventDetailsPanelProps> = ({ event, onDismiss }) => {
  return (
    <Panel
      isOpen={!!event}
      onDismiss={onDismiss}
      type={PanelType.medium}
      headerText={event?.subject}
      closeButtonAriaLabel="Close"
    >
      {event && (
        <Stack tokens={{ childrenGap: 12 }} className={styles.eventDetailsPanel}>
          <Stack horizontal tokens={{ childrenGap: 8 }} verticalAlign="center">
            <Icon iconName="Clock" />
            <Text>
              {event.isAllDay ? 'All day' : `${formatDateTime(event.start)} - ${formatDateTime(event.end)}`}
            </Text>
          </Stack>
          {event.organizerName && (
            <Stack horizontal tokens={{ childrenGap: 8 }} verticalAlign="center">
              <Icon iconName="Contact" />
              <Text>{event.organizerName}</Text>
            </Stack>
          )}
          {event.location && (
            <Stack horizontal tokens={{ childrenGap: 8 }} verticalAlign="center">
              <Icon iconName="MapPin" />
              <Text>{event.location}</Text>
            </Stack>
          )}
          {event.bodyPreview && (
            <Text block className={styles.bodyPreview}>
              {event.bodyPreview}
            </Text>
          )}
        </Stack>
      )}
    </Panel>
  );
};

export default EventDetailsPanel;
