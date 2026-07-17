import { CalendarView } from '../models/CalendarView';

export function startOfDay(date: Date): Date {
  const result = new Date(date);
  result.setHours(0, 0, 0, 0);
  return result;
}

export function endOfDay(date: Date): Date {
  const result = new Date(date);
  result.setHours(23, 59, 59, 999);
  return result;
}

export function addDays(date: Date, days: number): Date {
  const result = new Date(date);
  result.setDate(result.getDate() + days);
  return result;
}

export function addMonths(date: Date, months: number): Date {
  const result = new Date(date);
  result.setMonth(result.getMonth() + months);
  return result;
}

export function isSameDay(a: Date, b: Date): boolean {
  return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
}

export function startOfWeek(date: Date): Date {
  const result = startOfDay(date);
  result.setDate(result.getDate() - result.getDay());
  return result;
}

export function endOfWeek(date: Date): Date {
  return endOfDay(addDays(startOfWeek(date), 6));
}

export function startOfMonth(date: Date): Date {
  return new Date(date.getFullYear(), date.getMonth(), 1);
}

/** 6-week grid (42 days) starting on the Sunday on/before the 1st of the month, so the month view always shows full weeks. */
export function getMonthGridDays(date: Date): Date[] {
  const gridStart = startOfWeek(startOfMonth(date));
  return Array.from({ length: 42 }, (_unused, i) => addDays(gridStart, i));
}

export function getRangeForView(view: CalendarView, date: Date): { start: Date; end: Date } {
  switch (view) {
    case CalendarView.Day:
      return { start: startOfDay(date), end: endOfDay(date) };
    case CalendarView.Week:
      return { start: startOfWeek(date), end: endOfWeek(date) };
    case CalendarView.Month:
    default: {
      const gridDays = getMonthGridDays(date);
      return { start: startOfDay(gridDays[0]), end: endOfDay(gridDays[gridDays.length - 1]) };
    }
  }
}

export function navigate(view: CalendarView, date: Date, delta: number): Date {
  switch (view) {
    case CalendarView.Day:
      return addDays(date, delta);
    case CalendarView.Week:
      return addDays(date, delta * 7);
    case CalendarView.Month:
    default:
      return addMonths(date, delta);
  }
}

export function getRangeLabel(view: CalendarView, date: Date): string {
  switch (view) {
    case CalendarView.Day:
      return date.toLocaleDateString(undefined, { weekday: 'long', month: 'long', day: 'numeric', year: 'numeric' });
    case CalendarView.Week: {
      const start = startOfWeek(date);
      const end = addDays(start, 6);
      const sameMonth = start.getMonth() === end.getMonth();
      const startLabel = start.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
      const endLabel = end.toLocaleDateString(undefined, {
        month: sameMonth ? undefined : 'short',
        day: 'numeric',
        year: 'numeric'
      });
      return `${startLabel} - ${endLabel}`;
    }
    case CalendarView.Month:
    default:
      return date.toLocaleDateString(undefined, { month: 'long', year: 'numeric' });
  }
}
