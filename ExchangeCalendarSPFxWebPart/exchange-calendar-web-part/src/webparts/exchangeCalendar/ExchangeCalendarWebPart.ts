import * as React from 'react';
import * as ReactDom from 'react-dom';
import { Version } from '@microsoft/sp-core-library';
import {
  type IPropertyPaneConfiguration,
  PropertyPaneTextField,
  PropertyPaneDropdown
} from '@microsoft/sp-property-pane';
import { BaseClientSideWebPart } from '@microsoft/sp-webpart-base';
import type { IReadonlyTheme } from '@microsoft/sp-component-base';

import * as strings from 'ExchangeCalendarWebPartStrings';
import ExchangeCalendar from './components/ExchangeCalendar';
import { IExchangeCalendarProps } from './components/IExchangeCalendarProps';
import { CalendarView } from './models/CalendarView';

export interface IExchangeCalendarWebPartProps {
  calendarEmail: string;
  defaultView: CalendarView;
}

export default class ExchangeCalendarWebPart extends BaseClientSideWebPart<IExchangeCalendarWebPartProps> {

  public render(): void {
    const element: React.ReactElement<IExchangeCalendarProps> = React.createElement(
      ExchangeCalendar,
      {
        calendarEmail: this.properties.calendarEmail || 'Calendar@RSE-Law.com',
        defaultView: this.properties.defaultView || CalendarView.Month,
        graphClientFactory: this.context.msGraphClientFactory
      }
    );

    ReactDom.render(element, this.domElement);
  }

  protected onDispose(): void {
    ReactDom.unmountComponentAtNode(this.domElement);
  }

  protected get dataVersion(): Version {
    return Version.parse('1.0');
  }

  protected onThemeChanged(currentTheme: IReadonlyTheme | undefined): void {
    if (!currentTheme) {
      return;
    }

    const { semanticColors, palette } = currentTheme;
    this.domElement.style.setProperty('--bodyText', semanticColors?.bodyText || null);
    this.domElement.style.setProperty('--link', semanticColors?.link || null);
    this.domElement.style.setProperty('--linkHovered', semanticColors?.linkHovered || null);
    this.domElement.style.setProperty('--neutralLight', palette?.neutralLight || null);
    this.domElement.style.setProperty('--neutralLighter', palette?.neutralLighter || null);
    this.domElement.style.setProperty('--neutralSecondary', palette?.neutralSecondary || null);
    this.domElement.style.setProperty('--themePrimary', palette?.themePrimary || null);
    this.domElement.style.setProperty('--themeLighter', palette?.themeLighter || null);
  }

  protected getPropertyPaneConfiguration(): IPropertyPaneConfiguration {
    return {
      pages: [
        {
          header: {
            description: strings.PropertyPaneDescription
          },
          groups: [
            {
              groupName: strings.BasicGroupName,
              groupFields: [
                PropertyPaneTextField('calendarEmail', {
                  label: strings.CalendarEmailFieldLabel
                }),
                PropertyPaneDropdown('defaultView', {
                  label: strings.DefaultViewFieldLabel,
                  options: [
                    { key: CalendarView.Day, text: strings.ViewDayLabel },
                    { key: CalendarView.Week, text: strings.ViewWeekLabel },
                    { key: CalendarView.Month, text: strings.ViewMonthLabel }
                  ]
                })
              ]
            }
          ]
        }
      ]
    };
  }
}
