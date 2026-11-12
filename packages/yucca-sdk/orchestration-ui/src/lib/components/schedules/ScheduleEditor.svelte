<script lang="ts">
  import { useSchedules } from "$lib/services/schedule.service";
  import {
    describeCron,
    resolveCron,
    runsMoreThanHourly,
    toSchedulePreset,
    type SchedulePreset,
  } from "$lib/utils/cron";
  import {
    Button,
    Field,
    HelperText,
    HStack,
    Input,
    LoadingSpinner,
    Select,
    Text,
  } from "@immich/ui";
  import cronValidate from "cron-validate";
  import { msg, t } from "svelte-i18n-lingui";

  type Props = {
    cron: string;
    disabled?: boolean;
    invalid?: boolean;
  };

  let {
    cron = $bindable(),
    disabled = false,
    invalid = $bindable(false),
  }: Props = $props();

  const cronValidateModule = cronValidate as unknown as {
    default: typeof cronValidate;
  };
  const validate =
    typeof cronValidate === "function"
      ? cronValidate
      : cronValidateModule.default;

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
  const waitingForDefaults = $derived(!!preset && !schedules.data?.defaults);
  const cronInvalid = $derived(
    frequency === "custom" && !preset && validate(cron).isError(),
  );
  const startTimes = $derived(
    Array.from({ length: 24 }, (_, hour) => ({
      value: String(hour),
      label: `${String(hour).padStart(2, "0")}:${fields[0]?.padStart(2, "0")}`,
    })),
  );

  $effect(() => {
    invalid = cronInvalid;
  });

  const setField = (index: number, value: string) => {
    const updated = [...fields];
    updated[index] = value;
    cron = updated.join(" ");
  };
</script>

<Field label={$t`Frequency`} {disabled}>
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

{#if waitingForDefaults}
  {#if schedules.isError}
    <HelperText color="danger">{$t`Failed to load default schedule`}</HelperText
    >
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
  <HStack gap={2} class="items-start">
    {#if frequency === "weekly"}
      <Field label={$t`Day of week`} {disabled}>
        <Select
          options={weekdays.map((label, index) => ({
            value: String(index),
            label: $t(label),
          }))}
          value={String(Number(fields[4]) % 7)}
          onChange={(value) => setField(4, value)}
        />
      </Field>
    {:else if frequency === "monthly"}
      <Field label={$t`Day of month`} {disabled}>
        <Select
          options={monthDays}
          value={String(Number(fields[2]))}
          onChange={(value) => setField(2, value)}
        />
      </Field>
    {/if}

    <Field label={$t`Start time`} {disabled}>
      <Select
        options={startTimes}
        value={String(Number(fields[1]))}
        onChange={(value) => setField(1, value)}
      />
    </Field>
  </HStack>
{/if}

{#if !waitingForDefaults && !cronInvalid}
  <HStack gap={2} class="items-center justify-between">
    <Text size="small" color="muted">
      {$t`Backups will run`}
      {describeCron(effectiveCron)}.
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
{/if}
