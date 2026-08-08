import { HttpClient } from '@microsoft/sp-http';

export interface IOutlookSearchProps {
  httpClient: HttpClient;
  searchServiceUrl: string;
  indexName: string;
  apiKey: string;
  apiVersion: string;
  suggesterName: string;
  pageSize: number;
}
