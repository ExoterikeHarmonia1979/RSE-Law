# SPFx Exchange Calendar Web Part — Build Prompt

**Goal:** Build an SPFx web part that displays the shared Exchange calendar `Calendar@RSE-Law.com` with switchable Day, Week, and Month views (Month as the default), using React and Fluent UI v8.

**Tenant:** `https://reiszsidermaneisenberg.sharepoint.com/`
**Calendar:** `Calendar@RSE-Law.com` (shared mailbox calendar)

**Tech stack:**
- SPFx (latest LTS toolchain compatible with the tenant) with the React framework
- Fluent UI v8 (`@fluentui/react`) for all UI components (buttons, view switcher, spinners, panels, etc.)
- Microsoft Graph API for calendar data, called via SPFx's built-in `AadHttpClient` / `MSGraphClientV3` (delegated permissions — the request runs as the signed-in user, so `Calendar@RSE-Law.com` must be shared/delegated to users who will view the web part)
- Custom-built Day/Week/Month grid views styled with Fluent UI (no third-party calendar library)

**Functional requirements:**
1. On load, fetch events for `Calendar@RSE-Law.com` for the currently visible date range and render them in a **Month view** by default.
2. Provide a view switcher (Fluent UI `Pivot` or segmented control) to toggle between **Day**, **Week**, and **Month** views without a full page reload.
3. Each view should support navigating forward/backward (prev/next day, week, or month) and a "Today" button to jump back to the current date.
4. Month view: standard calendar grid, each day cell shows up to a few events with a "+N more" overflow indicator.
5. Week view: 7-day column grid with time-of-day rows for timed events, plus an all-day event row.
6. Day view: single-day agenda/time-grid showing all events with start/end times.
7. Clicking an event opens a Fluent UI `Panel` or `Dialog` showing event details (subject, organizer, start/end time, location, body preview).
8. Handle loading state (Fluent `Spinner`) and error state (Fluent `MessageBar`) if the Graph call fails (e.g., no calendar access).
9. Web part property pane should let an admin configure the target calendar email (default to `Calendar@RSE-Law.com`) and the default view (default to Month), so it's reusable for other calendars later.

**Data access details:**
- Use Graph endpoint `GET /users/{calendarEmail}/calendarView?startDateTime=...&endDateTime=...` scoped to the visible range of the active view, requesting the `Calendars.Read` (or `Calendars.Read.Shared`) delegated permission.
- Register the required Graph permission in `config/package-solution.json` (`webApiPermissionRequests`) so a tenant admin can approve it in the SharePoint admin center.
- Handle pagination (`@odata.nextLink`) if a range returns more events than one page.

**Non-functional:**
- Follow SPFx web part conventions (`manifest.json`, `*WebPart.ts`, `*WebPart.manifest.json`, property pane in `IPropertyPaneConfiguration`).
- Keep state management simple (React hooks/context) — no Redux or other state library unless the scope grows to need it.
- No speculative configurability beyond what's listed above.

**Acceptance criteria:**
- Web part builds and runs via `gulp serve` in the SharePoint Workbench.
- Month view loads and displays real events from `Calendar@RSE-Law.com` for a signed-in user with calendar access.
- Switching Day/Week/Month preserves the currently selected date and re-fetches only the needed range.
- Clicking an event shows correct details.
- Missing/denied permissions show a clear error message rather than a blank screen or unhandled exception.
