import CreateScheduleModal from '$lib/components/schedules/dialogs/CreateScheduleModal.svelte';
import ConfigureScheduleModal from '$lib/components/schedules/dialogs/ConfigureScheduleModal.svelte';
import type { ScheduleDto } from '$lib/fetch-client';
import '../../../routes/layout.css';
import { DateTime } from 'luxon';
import { page } from 'vitest/browser';
import { render } from 'vitest-browser-svelte';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const state = vi.hoisted(() => ({
  id: '1cbf642b-c244-42f2-a886-77ad1d3ae343',
  defaults: {
    daily: '23 3 * * *',
    weekly: '23 3 * * 2',
    monthly: '23 3 12 * *',
  },
  tz: Intl.DateTimeFormat().resolvedOptions().timeZone,
  create: vi.fn(),
  update: vi.fn(),
}));

vi.mock('$lib/services/repository.service', () => ({
  useRepositories: () => ({
    data: [{ id: state.id, name: 'Immich', worm: false }],
  }),
  useRepositoryEventHandler: () => ({}),
}));

vi.mock('$lib/services/schedule.service', () => ({
  useSchedules: () => ({
    data: { schedules: [], defaults: state.defaults, tz: state.tz },
  }),
  useCreateSchedule: () => ({ mutate: state.create }),
  useUpdateSchedule: () => ({ mutate: state.update }),
}));

vi.mock('svelte-i18n-lingui', async () => {
  const { get, readable } = await import('svelte/store');
  const t = readable(
    (
      input:
        | TemplateStringsArray
        | string
        | { message: string; values: Record<string, string> },
    ) => {
      if (typeof input === 'string') {
        return input;
      }

      if ('message' in input) {
        let message = input.message;
        for (const [key, value] of Object.entries(input.values)) {
          message = message.replaceAll(`{${key}}`, value);
        }

        return message;
      }

      return input.join('');
    },
  );
  return {
    msg: (strings: TemplateStringsArray) => strings.join(''),
    t,
    gt: get(t),
  };
});

const button = (name: string) =>
  page.getByRole('button', { name, exact: true });
const choose = async (field: string, option: string) => {
  await page.getByRole('button', { name: field }).click();
  await page.getByRole('option', { name: option, exact: true }).click();
};
const scheduleInput = () =>
  page.getByRole('textbox', { name: 'Schedule', exact: true });

const openCreate = async () => {
  await render(CreateScheduleModal, { onClose: vi.fn() });
  await page.getByRole('textbox', { name: 'Name', exact: true }).fill('Photos');
  await button('Add Immich').click();
};

const localRun = (year: number, month: number, day: number) =>
  DateTime.fromObject({ year, month, day, hour: 5 }, { zone: state.tz })
    .toLocal()
    .toLocaleString({ ...DateTime.DATETIME_MED_WITH_WEEKDAY, timeZoneName: 'short' });

const fillCustom = async (cron: string) => {
  state.tz = 'Pacific/Kiritimati';
  vi.useFakeTimers({ toFake: ['Date'] });
  vi.setSystemTime(Date.parse('2026-01-01T12:00:00Z'));
  await openCreate();
  await choose('Frequency', 'Custom');
  await scheduleInput().fill(cron);
};

const nextRuns = () => page.getByRole('list', { name: 'Next runs' }).getByRole('listitem');

const created = () => state.create.mock.lastCall?.[0];

describe('Schedule dialogs', () => {
  beforeEach(() => {
    state.create.mockClear();
    state.update.mockClear();
  });

  afterEach(() => {
    vi.useRealTimers();
    state.tz = Intl.DateTimeFormat().resolvedOptions().timeZone;
  });

  it('creates schedules on the installation daily default', async () => {
    await openCreate();
    await expect
      .element(page.getByRole('button', { name: 'Frequency' }))
      .toHaveTextContent('Daily');
    await expect
      .element(
        page.getByText('Backups will run between 03:00 and 04:00, every day.'),
      )
      .toBeVisible();
    await button('Save').click();
    expect(created()).toMatchObject({
      cron: '@daily',
      repositories: [state.id],
    });
  });

  it('saves an explicit expression after changing the day and returns to the preset with Use default', async () => {
    await openCreate();
    await choose('Frequency', 'Weekly');
    await expect
      .element(page.getByRole('button', { name: 'Day of week' }))
      .toHaveTextContent('Tuesday (at default time)');
    await expect.element(button('Use default')).not.toBeInTheDocument();

    await choose('Day of week', 'Thursday');
    await button('Save').click();
    expect(created()).toMatchObject({ cron: '0 3 * * 4' });

    await button('Use default').click();
    await expect.element(button('Use default')).not.toBeInTheDocument();
    await button('Save').click();
    expect(created()).toMatchObject({ cron: '@weekly' });
  });

  it('offers whole hours and the installation default as start times', async () => {
    await openCreate();
    await choose('Start time', '05:00');
    await button('Save').click();
    expect(created()).toMatchObject({ cron: '0 5 * * *' });

    await choose('Start time', 'Between 03:00 and 04:00 (default)');
    await button('Save').click();
    expect(created()).toMatchObject({ cron: '@daily' });
  });

  it.each([
    {
      frequency: 'Weekly',
      field: 'Day of week',
      day: 'Tuesday',
      cron: '0 3 * * 2',
      preset: '@weekly',
    },
    {
      frequency: 'Monthly',
      field: 'Day of month',
      day: '12',
      cron: '0 3 12 * *',
      preset: '@monthly',
    },
  ])(
    'offers one default choice for $frequency and shows time only for an explicit day',
    async ({ frequency, field, day, cron, preset }) => {
      await openCreate();
      await choose('Frequency', frequency);
      await expect
        .element(page.getByRole('button', { name: field }))
        .toHaveTextContent(day + ' (at default time)');
      await expect
        .element(page.getByRole('button', { name: 'Start time' }))
        .not.toBeInTheDocument();

      await choose(field, day);
      await expect
        .element(page.getByRole('button', { name: 'Start time' }))
        .toHaveTextContent('03:00');
      await button('Save').click();
      expect(created()).toMatchObject({ cron });

      await choose('Start time', '05:00');
      await choose(field, day + ' (at default time)');
      await expect
        .element(page.getByRole('button', { name: 'Start time' }))
        .not.toBeInTheDocument();
      await button('Save').click();
      expect(created()).toMatchObject({ cron: preset });
    },
  );

  it('keeps a saved daily time explicit even when it matches the installation default', async () => {
    const schedule: ScheduleDto = {
      id: 'schedule',
      name: 'Nightly',
      cron: '23 3 * * *',
      paused: false,
      repositories: [state.id],
    };
    await render(ConfigureScheduleModal, { schedule, onClose: vi.fn() });
    await expect
      .element(page.getByRole('button', { name: 'Start time' }))
      .toHaveTextContent('03:23');
    await button('Save').click();
    expect(state.update.mock.lastCall?.[0]).toMatchObject({
      dto: { cron: '23 3 * * *' },
    });
    await choose('Start time', 'Between 03:00 and 04:00 (default)');
    await button('Save').click();
    expect(state.update.mock.lastCall?.[0]).toMatchObject({
      dto: { cron: '@daily' },
    });
  });

  it('validates custom expressions before saving', async () => {
    await openCreate();
    await choose('Frequency', 'Custom');
    await expect.element(scheduleInput()).toHaveValue('23 3 * * *');
    await scheduleInput().fill('invalid');
    await expect
      .element(
        page.getByText('Enter a valid cron expression, for example 0 3 * * *'),
      )
      .toBeVisible();
    await expect.element(button('Save')).toBeDisabled();
    await scheduleInput().fill('*/30 1-5 * * 1-5');
    await button('Save').click();
    expect(created()).toMatchObject({ cron: '*/30 1-5 * * 1-5' });
  });

  it("lists the next three runs from the scheduler's time zone in local time", async () => {
    await fillCustom('0 5 * * 0');
    await expect.element(page.getByText(/\(Pacific\/Kiritimati\)\./)).toBeVisible();
    await expect.element(nextRuns().first()).toHaveTextContent(localRun(2026, 1, 4));
    expect(nextRuns().elements().map((run) => run.textContent?.trim())).toEqual([
      localRun(2026, 1, 4),
      localRun(2026, 1, 11),
      localRun(2026, 1, 18),
    ]);
  });

  it('lists only the runs a rare schedule has', async () => {
    await fillCustom('0 5 29 2 *');

    await expect.element(nextRuns().first()).toHaveTextContent(localRun(2028, 2, 29));
    expect(nextRuns().elements().map((run) => run.textContent?.trim())).toEqual([
      localRun(2028, 2, 29),
      localRun(2032, 2, 29),
    ]);
  });

  it('says when a schedule never runs and keeps the editor usable', async () => {
    await fillCustom('0 5 31 2 *');

    await expect
      .element(page.getByText('This schedule never runs. Check the day and month.'))
      .toBeVisible();

    await scheduleInput().fill('0 5 * * 0');
    await expect.element(nextRuns().first()).toHaveTextContent(localRun(2026, 1, 4));
  });

  it('keeps a default schedule to its window without exact run times', async () => {
    await openCreate();
    await expect
      .element(
        page.getByText('Backups will run between 03:00 and 04:00, every day.'),
      )
      .toBeVisible();
    await expect
      .element(page.getByRole('list', { name: 'Next runs' }))
      .not.toBeInTheDocument();
  });

  it('resolves a preset typed as a custom expression', async () => {
    await openCreate();
    await choose('Frequency', 'Custom');
    await scheduleInput().fill('@weekly');
    await expect.element(scheduleInput()).toHaveValue('@weekly');
    await expect
      .element(
        page.getByText(
          'Backups will run between 03:00 and 04:00, only on Tuesday.',
        ),
      )
      .toBeVisible();
    await button('Save').click();
    expect(created()).toMatchObject({ cron: '@weekly' });
  });

  it.each([
    { cron: '17 4 * * 4', frequency: 'Weekly' },
    { cron: '41 5 31 * *', frequency: 'Monthly' },
    { cron: '*/30 1-5 * * 1-5', frequency: 'Custom' },
  ])(
    'opens $cron as $frequency and saves it unchanged',
    async ({ cron, frequency }) => {
      const schedule: ScheduleDto = {
        id: 'schedule',
        name: 'Nightly',
        cron,
        paused: false,
        repositories: [state.id],
      };
      await render(ConfigureScheduleModal, { schedule, onClose: vi.fn() });
      await expect
        .element(page.getByRole('button', { name: 'Frequency' }))
        .toHaveTextContent(frequency);
      await button('Save').click();
      expect(state.update.mock.lastCall?.[0]).toMatchObject({
        id: schedule.id,
        dto: { cron },
      });
    },
  );
});
