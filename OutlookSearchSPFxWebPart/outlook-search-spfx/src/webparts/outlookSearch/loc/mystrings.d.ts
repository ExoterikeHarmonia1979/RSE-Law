declare interface IOutlookSearchWebPartStrings {
  PropertyPaneDescription: string;
  ConnectionGroupName: string;
  BehaviorGroupName: string;
  SearchServiceUrlLabel: string;
  IndexNameLabel: string;
  ApiKeyLabel: string;
  ApiKeyDescription: string;
  ApiVersionLabel: string;
  SuggesterNameLabel: string;
  SuggesterNameDescription: string;
  PageSizeLabel: string;
  EmlPreviewUrlLabel: string;
  EmlPreviewUrlDescription: string;
}

declare module 'OutlookSearchWebPartStrings' {
  const strings: IOutlookSearchWebPartStrings;
  export = strings;
}
