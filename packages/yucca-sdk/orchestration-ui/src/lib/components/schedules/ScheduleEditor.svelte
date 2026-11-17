<script lang="ts">
  import { useSchedules } from "$lib/services/schedule.service";
  import {
    describeSchedule,
    formatTime,
    isValidCron,
    resolveCron,
    runsMoreThanHourly,
    toDefaultWindow,
    toSchedulePreset,
    type SchedulePreset,
  } from "$lib/utils/cron";
  import { CronTime } from "cron";
  import { DateTime } from "luxon";
  import {
    Button,
    Field,
    HelperText,
    HStack,
    Input,
    LoadingSpinner,
    Select,
    Stack,
    Text,
  } from "@immich/ui";
  import { msg, t } from "svelte-i18n-lingui";

  type Props = {
    cron: string;
    disabled?: boolean;
  };

  let {
    cron = $bindable(),
    disabled = false,
  }: Props = $props();

  const frequencies = [
    { value: "daily", label: msg`Daily` },
    { value: "weekly", label: msg`Weekly` },
    { value: "monthly", label: msg`Monthly` },
    { value: "custom", label: msg`Custom` },
  ] as const;
  const weekdays = [
    msg`Sunday`,
    msg`Monday`,
    msg`Tuesday`,
    msg`Wednesday`,
    msg`Thursday`,
    msg`Friday`,
    msg`Saturday`,
  ];
  const monthDays = Array.from({ length: 31 }, (_, index) => ({
    value: String(index + 1),
    label: String(index + 1),
  }));
  const isNumber = (field: string | undefined) => /^\d+$/.test(field ?? "");

  const schedules = useSchedules();
  const nextRunsId = $props.id();
  let editingCustom = $state(false);

  const preset = $derived(toSchedulePreset(cron));
  const effectiveCron = $derived(resolveCron(cron, schedules.data?.defaults));
  const fields = $derived(effectiveCron.trim().split(/\s+/));
  const pattern = $derived.by((): SchedulePreset | undefined => {
    const [minute, hour, day, month, weekday] = fields;
    if (fields.length !== 5 || !isNumber(minute) || !isNumber(hour) || month !== "*") {
      return undefined;
    }

    if (day === "*") {
      return weekday === "*" ? "daily" : isNumber(weekday) ? "weekly" : undefined;
    }

    return isNumber(day) && weekday === "*" ? "monthly" : undefined;
  });
  const frequency = $derived(
    editingCustom ? "custom" : (preset ?? pattern ?? "custom"),
  );
  const cronInvalid = $derived(!isValidCron(cron));
  const nextRuns = $derived(
    cronInvalid ? [] : new CronTime(effectiveCron).sendAt(3),
  );
  const defaultExpression = $derived(
    frequency === "custom" ? undefined : schedules.data?.defaults[frequency],
  );
  const dayOptions = $derived.by(() => {
    const options =
      frequency === "weekly"
        ? weekdays.map((label, index) => ({
            value: String(index),
            label: $t(label),
          }))
        : monthDays;
    const defaultDay =
      defaultExpression?.split(" ")[frequency === "weekly" ? 4 : 2];
    return options.flatMap((option) =>
      option.value === defaultDay
        ? [
            option,
            {
              value: "default",
              label: $t({
                message: "{day} (at default time)",
                values: { day: option.label },
              }),
            },
          ]
        : [option],
    );
  });
  const startTime = $derived(`${Number(fields[1])}:${Number(fields[0])}`);
  const defaultStartTime = $derived.by(() => {
    const [minute, hour] = defaultExpression?.split(" ") ?? [];
    return defaultExpression ? `${Number(hour)}:${Number(minute)}` : undefined;
  });
  const defaultWindow = $derived(
    defaultExpression ? toDefaultWindow(defaultExpression) : undefined,
  );
  const startTimes = $derived(
    [
      ...new Set([
        ...Array.from({ length: 24 }, (_, hour) => `${hour}:0`),
        startTime,
        ...(frequency === "daily" && defaultStartTime
          ? [defaultStartTime]
          : []),
      ]),
    ]
      .map((time) => time.split(":").map(Number))
      .toSorted(([a = 0, b = 0], [c = 0, d = 0]) => a * 60 + b - (c * 60 + d))
      .flatMap(([hour = 0, minute = 0]) => {
        const value = `${hour}:${minute}`;
        const options =
          minute === 0 || (!preset && value === startTime)
            ? [{ value, label: formatTime(hour, minute) }]
            : [];
        if (
          frequency === "daily" &&
          value === defaultStartTime &&
          defaultWindow
        ) {
          options.push({
            value: "default",
            label: $t({
              message: "Between {start} and {end} (default)",
              values: defaultWindow,
            }),
          });
        }

        return options;
      }),
  );

  const setFields = (changes: Record<number, string>) => {
    cron = fields.map((field, index) => changes[index] ?? field).join(" ");
  };
</script>

<Field label={$t`Frequency`} disabled={disabled || schedules.isLoading || schedules.isError}>
  <Select
    options={frequencies.map((option) => ({
      ...option,
      label: $t(option.label),
    }))}
    value={frequency}
    onChange={(value) => {
      editingCustom = value === "custom";
      cron = value === "custom" ? effectiveCron : `@${value}`;
    }}
  />
</Field>

{#if !schedules.data}
  {#if schedules.isError}
    <Text size="small" color="danger">{$t`Failed to load default schedule`}</Text>
  {:else}
    <LoadingSpinner />
  {/if}
{:else if frequency === "custom"}
  <Field
    label={$t`Schedule`}
    description={$t`Uses cron syntax`}
    invalid={cronInvalid}
    {disabled}
  >
    <Input bind:value={cron} />
    {#if cronInvalid}
      <HelperText color="danger"
        >{$t`Enter a valid cron expression, for example 0 3 * * *`}</HelperText
      >
    {:else if runsMoreThanHourly(cron)}
      <HelperText color="warning"
        >{$t`This schedule runs more than once an hour. A * in the minute field runs a backup every minute.`}</HelperText
      >
    {/if}
  </Field>
{:else}
  {#if frequency === "weekly" || frequency === "monthly"}
    <Field
      label={frequency === "weekly" ? $t`Day of week` : $t`Day of month`}
      {disabled}
    >
      <Select
        options={dayOptions}
        value={preset
          ? "default"
          : frequency === "weekly"
            ? String(Number(fields[4]) % 7)
            : String(Number(fields[2]))}
        onChange={(value) => {
          if (value === "default") {
            cron = `@${frequency}`;
            return;
          }

          setFields({
            0: preset ? "0" : fields[0],
            [frequency === "weekly" ? 4 : 2]: value,
          });
        }}
      />
    </Field>
  {/if}

  {#if frequency === "daily" || !preset}
    <Field label={$t`Start time`} {disabled}>
      <Select
        options={startTimes}
        value={preset ? "default" : startTime}
        onChange={(value) => {
          if (value === "default") {
            cron = "@daily";
            return;
          }

          const [hour = "0", minute = "0"] = value.split(":");
          setFields({ 0: minute, 1: hour });
        }}
      />
    </Field>
  {/if}
{/if}

{#if schedules.data && !cronInvalid}
  <HStack gap={2} class="items-center justify-between">
    <Text size="small" color="muted">
      {$t`Backups will run`}
      {describeSchedule(cron, schedules.data.defaults, schedules.data.tz)}.
      {#if frequency === "monthly" && Number(fields[2]) > 28}
        {$t`Days 29, 30 and 31 only run in months that have that day.`}
      {/if}
    </Text>
    {#if frequency !== "custom" && !preset}
      <Button
        size="small"
        shape="round"
        variant="outline"
        class="shrink-0"
        {disabled}
        onclick={() => (cron = `@${frequency}`)}>{$t`Use default`}</Button
      >
    {/if}
  </HStack>

  {#if !preset}
    <Stack gap={1}>
      <Text id={nextRunsId} size="small" color="muted" fontWeight="bold"
        >{$t`Next runs`}</Text
      >
      <ul aria-labelledby={nextRunsId}>
        {#each nextRuns as run (run.toMillis())}
          <li>
            <Text size="small" color="muted"
              >{run.toLocaleString(DateTime.DATETIME_MED_WITH_WEEKDAY)}</Text
            >
          </li>
        {/each}
      </ul>
    </Stack>
  {/if}
{/if}
