/**
 * Translates an Outlook-style search string into an Azure AI Search
 * (full Lucene) query plus an OData $filter.
 *
 * Supported prefixes (same semantics as the Outlook search bar):
 *   from:scott            from:"Scott Dallas"
 *   to:eisenberg          cc:matters
 *   subject:"please review"
 *   received:2026-08-07   (that whole day)
 *   before:2026-08-01     after:2026-07-01
 *   hasattachment:yes     (requires an attachment_names collection field)
 * Everything else is matched against all searchable fields with
 * searchMode=all, mirroring Outlook's "match every word" behavior.
 */
export interface IParsedQuery {
  search: string;
  filter: string | undefined;
}

const FIELD_MAP: { [prefix: string]: string } = {
  from: 'metadata_message_from',
  to: 'metadata_message_to',
  cc: 'metadata_message_cc',
  subject: 'metadata_subject'
};

const DATE_FIELD = 'metadata_creation_date';

/** Escape characters that are operators in the full Lucene syntax. */
function escapeLucene(term: string): string {
  return term.replace(/([+\-!(){}[\]^"~*?:\\/]|&&|\|\|)/g, '\\$1');
}

function luceneTerm(value: string, wasQuoted: boolean): string {
  if (wasQuoted) {
    return `"${value.replace(/(["\\])/g, '\\$1')}"`;
  }
  return escapeLucene(value);
}

function dayRangeFilter(isoDay: string): string | undefined {
  const start = new Date(`${isoDay}T00:00:00Z`);
  if (isNaN(start.getTime())) {
    return undefined;
  }
  const end = new Date(start.getTime() + 24 * 60 * 60 * 1000);
  return `${DATE_FIELD} ge ${start.toISOString()} and ${DATE_FIELD} lt ${end.toISOString()}`;
}

export function parseOutlookQuery(input: string): IParsedQuery {
  const searchParts: string[] = [];
  const filterParts: string[] = [];

  // token = prefix:value | prefix:"quoted value" | "quoted phrase" | word
  const tokenRe = /(\w+):(?:"([^"]*)"|(\S+))|"([^"]*)"|(\S+)/g;
  let m: RegExpExecArray | null = tokenRe.exec(input);

  while (m !== null) {
    const prefix = m[1] ? m[1].toLowerCase() : undefined;
    const prefixValue = m[2] !== undefined ? m[2] : m[3];
    const phrase = m[4];
    const word = m[5];

    if (prefix && prefixValue !== undefined) {
      const field = FIELD_MAP[prefix];
      if (field) {
        searchParts.push(`${field}:${luceneTerm(prefixValue, m[2] !== undefined)}`);
      } else if (prefix === 'received') {
        const f = dayRangeFilter(prefixValue);
        if (f) { filterParts.push(f); }
      } else if (prefix === 'before') {
        const d = new Date(`${prefixValue}T00:00:00Z`);
        if (!isNaN(d.getTime())) { filterParts.push(`${DATE_FIELD} lt ${d.toISOString()}`); }
      } else if (prefix === 'after') {
        const d = new Date(`${prefixValue}T00:00:00Z`);
        if (!isNaN(d.getTime())) { filterParts.push(`${DATE_FIELD} ge ${d.toISOString()}`); }
      } else if (prefix === 'hasattachment' || prefix === 'hasattachments') {
        filterParts.push(
          /^(yes|true|1)$/i.test(prefixValue)
            ? 'attachment_names/any()'
            : 'not attachment_names/any()'
        );
      } else {
        // Unknown prefix — treat the whole token as plain text, like Outlook does.
        searchParts.push(escapeLucene(`${prefix}:${prefixValue}`));
      }
    } else if (phrase !== undefined) {
      searchParts.push(luceneTerm(phrase, true));
    } else if (word !== undefined) {
      searchParts.push(escapeLucene(word));
    }

    m = tokenRe.exec(input);
  }

  return {
    search: searchParts.length > 0 ? searchParts.join(' ') : '*',
    filter: filterParts.length > 0 ? filterParts.join(' and ') : undefined
  };
}
