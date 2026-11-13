import ImmichSettingsSchedule from './ImmichSettingsSchedule.svelte';
import '../../../../../routes/layout.css';
import { page } from 'vitest/browser';
import { render } from 'vitest-browser-svelte';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const state = vi.hoisted(() => ({
  id: '1cbf642b-c244-42f2-a886-77ad1d3ae343',
  cron: '17 3 * * 4',
  defaults: {
    daily: '23 3 * * *',
    weekly: '23 3 * * 2',
    monthly: '23 3 12 * *',
  },
  mutate: vi.fn(),
}));

vi.mock('$lib/providers', () => ({ getProvider: () => ({ api: 'immich' }) }));

vi.mock('$lib/services/integrations.service', () => ({
  useIntegrations: () => ({
    data: {
      immichIntegration: {
        id: state.id,
        scheduleId: 'schedule',
        configuration: {
          dataFolders: ['upload'],
          backupConfiguration: true,
          libraries: ['all'],
        },
      },
    },
  }),
  useConfigureImmichIntegration: () => ({ mutate: state.mutate }),
  useIntegrationEventHandler: () => ({}),
}));

vi.mock('$lib/services/repository.service', () => ({
  useRepositories: () => ({
    data: [{ id: state.id, name: 'Immich', worm: false }],
  }),
  useRepositoryEventHandler: () => ({}),
}));

vi.mock('$lib/services/schedule.service', () => ({
  useSchedules: () => ({
    data: {
      schedules: [
        {
          id: 'schedule',
          cron: state.cron,
          paused: false,
        },
      ],
      defaults: state.defaults,
    },
  }),
  useScheduleEventHandler: () => ({}),
}));

vi.mock('svelte-i18n-lingui', async () => {
  const { readable } = await import('svelte/store');
  return {
    msg: (strings: TemplateStringsArray) => strings.join(''),
    t: readable(
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
    ),
  };
});

const button = (name: string) =>
  page.getByRole('button', { name, exact: true });
const choose = async (field: string, option: string) => {
  await page.getByRole('button', { name: field }).click();
  await page.getByRole('option', { name: option, exact: true }).click();
};

const open = async (cron: string) => {
  state.cron = cron;
  await render(ImmichSettingsSchedule);
  await page.getByRole('button', { name: 'Schedule', exact: false }).click();
};

const saved = () => state.mutate.mock.lastCall?.[0];

describe('Immich schedule settings', () => {
  beforeEach(() => {
    state.mutate.mockClear();
  });

  it.each([
    '@weekly',
    '17 3 * * 4',
    '41 5 31 * *',
    '23 4 * * 7',
    '*/15 3 * * *',
  ])('retains %s when saving without changes', async (cron) => {
    await open(cron);
    await button('Save').click();
    expect(saved()).toMatchObject({ cron });
  });

  it('prevents saving an invalid custom schedule and allows a corrected expression', async () => {
    await open('17 3 * * 4');
    await choose('Frequency', 'Custom');
    const input = page.getByRole('textbox', { name: 'Schedule', exact: true });
    await input.fill('invalid');
    await expect
      .element(
        page.getByText('Enter a valid cron expression, for example 0 3 * * *'),
      )
      .toBeVisible();
    await expect.element(button('Save')).toBeDisabled();
    expect(state.mutate).not.toHaveBeenCalled();
    await input.fill('*/30 1-5 * * 1-5');
    await button('Save').click();
    expect(saved()).toMatchObject({ cron: '*/30 1-5 * * 1-5' });
  });

  it('pauses backups without changing the saved schedule', async () => {
    await open('17 3 * * 4');
    await page
      .getByRole('switch', { name: 'Run backups automatically' })
      .click();
    await button('Save').click();
    expect(saved()).toMatchObject({ cron: '17 3 * * 4', paused: true });
  });

  it('shows the installation default day and time for a preset', async () => {
    await open('@weekly');
    await expect
      .element(page.getByRole('button', { name: 'Frequency' }))
      .toHaveTextContent('Weekly');
    await expect
      .element(page.getByRole('button', { name: 'Day of week' }))
      .toHaveTextContent('Tuesday (at default time)');
    await expect
      .element(page.getByRole('button', { name: 'Start time' }))
      .not.toBeInTheDocument();
    await expect
      .element(
        page.getByText(
          'Backups will run between 03:00 and 04:00, only on Tuesday.',
        ),
      )
      .toBeVisible();
    await expect.element(button('Use default')).not.toBeInTheDocument();
  });

  it('shows saved days and minutes, saves edits and resets to the saved values', async () => {
    await open('17 3 * * 4');
    await expect
      .element(page.getByRole('button', { name: 'Day of week' }))
      .toHaveTextContent('Thursday');
    await expect
      .element(page.getByRole('button', { name: 'Start time' }))
      .toHaveTextContent('03:17');
    await choose('Day of week', 'Tuesday');
    await button('Save').click();
    expect(saved()).toMatchObject({ cron: '17 3 * * 2' });
    await choose('Start time', '06:00');
    await button('Save').click();
    expect(saved()).toMatchObject({ cron: '0 6 * * 2' });
    await button('Reset').click();
    await expect
      .element(page.getByRole('button', { name: 'Day of week' }))
      .toHaveTextContent('Thursday');
  });

  it('changes the monthly day without discarding the minute', async () => {
    await open('41 5 31 * *');
    await expect
      .element(page.getByRole('button', { name: 'Day of month' }))
      .toHaveTextContent('31');
    await choose('Day of month', '1');
    await button('Save').click();
    expect(saved()).toMatchObject({ cron: '41 5 1 * *' });
  });

  it('starts from the installation default when the frequency changes', async () => {
    await open('17 3 * * 4');
    await choose('Frequency', 'Monthly');
    await expect
      .element(page.getByRole('button', { name: 'Day of month' }))
      .toHaveTextContent('12 (at default time)');
    await button('Save').click();
    expect(saved()).toMatchObject({ cron: '@monthly' });
  });

  it('returns an explicit schedule to the default with Use default', async () => {
    await open('17 3 * * 4');
    await button('Use default').click();
    await expect
      .element(page.getByRole('button', { name: 'Day of week' }))
      .toHaveTextContent('Tuesday (at default time)');
    await button('Save').click();
    expect(saved()).toMatchObject({ cron: '@weekly' });
  });
});
