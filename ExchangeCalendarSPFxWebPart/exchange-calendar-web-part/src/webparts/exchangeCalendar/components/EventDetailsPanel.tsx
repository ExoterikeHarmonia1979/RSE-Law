import * as React from 'react';
import { Icon, Panel, PanelType, Stack, Text } from '@fluentui/react';
import type { ICalendarEvent } from '../models/ICalendarEvent';
import styles from './EventDetailsPanel.module.scss';
import { rseGold, rseNavy } from '../styles/brandColors';

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
      styles={{
        headerText: {
          fontFamily: 'Georgia, "Times New Roman", serif',
          color: rseNavy,
          fontWeight: 600
        }
      }}
    >
      {event && (
        <Stack tokens={{ childrenGap: 12 }} className={styles.eventDetailsPanel}>
          <Stack horizontal tokens={{ childrenGap: 8 }} verticalAlign="center">
            <Icon iconName="Clock" styles={{ root: { color: rseGold } }} />
            <Text>
              {event.isAllDay ? 'All day' : `${formatDateTime(event.start)} - ${formatDateTime(event.end)}`}
            </Text>
          </Stack>
          {event.organizerName && (
            <Stack horizontal tokens={{ childrenGap: 8 }} verticalAlign="center">
              <Icon iconName="Contact" styles={{ root: { color: rseGold } }} />
              <Text>{event.organizerName}</Text>
            </Stack>
          )}
          {event.location && (
            <Stack horizontal tokens={{ childrenGap: 8 }} verticalAlign="center">
              <Icon iconName="MapPin" styles={{ root: { color: rseGold } }} />
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
