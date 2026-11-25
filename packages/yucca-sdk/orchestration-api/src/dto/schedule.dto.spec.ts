import { ScheduleListResponseDto } from './schedule.dto.js';

describe(ScheduleListResponseDto.name, () => {
  const response = {
    schedules: [],
    defaults: { daily: '23 3 * * *', weekly: '23 3 * * 2', monthly: '23 3 12 * *' },
  };

  it('accepts a response when the server time zone cannot be resolved', () => {
    expect(ScheduleListResponseDto.schema.parse(response)).toEqual(response);
  });

  it('preserves a known server time zone', () => {
    const withTimeZone = { ...response, tz: 'Europe/Berlin' };
    expect(ScheduleListResponseDto.schema.parse(withTimeZone)).toEqual(withTimeZone);
  });
});
