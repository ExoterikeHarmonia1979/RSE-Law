import * as React from 'react';
import * as ReactDom from 'react-dom';
import { Version } from '@microsoft/sp-core-library';
import {
  type IPropertyPaneConfiguration,
  PropertyPaneTextField,
  PropertyPaneSlider
} from '@microsoft/sp-property-pane';
import { BaseClientSideWebPart } from '@microsoft/sp-webpart-base';

import * as strings from 'OutlookSearchWebPartStrings';
import OutlookSearch from './components/OutlookSearch';
import { IOutlookSearchProps } from './components/IOutlookSearchProps';

export interface IOutlookSearchWebPartProps {
  searchServiceUrl: string;
  indexName: string;
  apiKey: string;
  apiVersion: string;
  suggesterName: string;
  pageSize: number;
  emlPreviewUrl: string;
}

export default class OutlookSearchWebPart extends BaseClientSideWebPart<IOutlookSearchWebPartProps> {

  public render(): void {
    const element: React.ReactElement<IOutlookSearchProps> = React.createElement(
      OutlookSearch,
      {
        httpClient: this.context.httpClient,
        searchServiceUrl: this.properties.searchServiceUrl || '',
        indexName: this.properties.indexName || '',
        apiKey: this.properties.apiKey || '',
        apiVersion: this.properties.apiVersion || '2024-07-01',
        suggesterName: this.properties.suggesterName || '',
        pageSize: this.properties.pageSize || 25,
        emlPreviewUrl: this.properties.emlPreviewUrl || ''
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

  protected getPropertyPaneConfiguration(): IPropertyPaneConfiguration {
    return {
      pages: [
        {
          header: {
            description: strings.PropertyPaneDescription
          },
          groups: [
            {
              groupName: strings.ConnectionGroupName,
              groupFields: [
                PropertyPaneTextField('searchServiceUrl', {
                  label: strings.SearchServiceUrlLabel,
                  placeholder: 'https://matterssearch.search.windows.net'
                }),
                PropertyPaneTextField('indexName', {
                  label: strings.IndexNameLabel,
                  placeholder: 'matters-index'
                }),
                PropertyPaneTextField('apiKey', {
                  label: strings.ApiKeyLabel,
                  description: strings.ApiKeyDescription
                }),
                PropertyPaneTextField('apiVersion', {
                  label: strings.ApiVersionLabel,
                  placeholder: '2024-07-01'
                }),
                PropertyPaneTextField('emlPreviewUrl', {
                  label: strings.EmlPreviewUrlLabel,
                  description: strings.EmlPreviewUrlDescription,
                  placeholder: 'https://regexazfunc.azurewebsites.net/api/EmlPreviewFunc?code=...'
                })
              ]
            },
            {
              groupName: strings.BehaviorGroupName,
              groupFields: [
                PropertyPaneTextField('suggesterName', {
                  label: strings.SuggesterNameLabel,
                  description: strings.SuggesterNameDescription
                }),
                PropertyPaneSlider('pageSize', {
                  label: strings.PageSizeLabel,
                  min: 10,
                  max: 100,
                  step: 5
                })
              ]
            }
          ]
        }
      ]
    };
  }
}
