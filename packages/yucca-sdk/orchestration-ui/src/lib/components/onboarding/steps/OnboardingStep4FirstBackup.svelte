<script lang="ts">
  import { HStack, Icon, Stack, Text } from "@immich/ui";
  import { mdiClock, mdiDownloadBox, mdiImageMultiple } from "@mdi/js";
  import OnboardingStepLayout, {
    type OnboardingStepAction,
  } from "./OnboardingStepLayout.svelte";
  import type { ScheduleDefaultsDto } from "$lib/fetch-client";
  import {
    describeSchedule,
    formatTime,
    resolveCron,
    withTimeZone,
  } from "$lib/utils/cron";
  import { CronTime } from "cron";
  import { DateTime } from "luxon";
  import { t } from "svelte-i18n-lingui";

  type Props = {
    cron: string;
    defaults?: ScheduleDefaultsDto;
    tz?: string;
    storageLocation: string;
    onStartBackup: () => void;
    loading?: boolean;
  };

  const {
    cron,
    defaults,
    tz,
    storageLocation,
    onStartBackup,
    loading = false,
  }: Props = $props();

  const schedule = $derived.by(() => {
    if (!defaults || !tz) {
      return "";
    }

    const description = describeSchedule(cron, defaults, tz);
    return description.charAt(0).toUpperCase() + description.slice(1);
  });
  const nextBackup = $derived.by(() => {
    if (!defaults || !tz) {
      return "";
    }

    const run = new CronTime(resolveCron(cron, defaults), tz).sendAt();
    const time = formatTime(run.hour, run.minute);
    return withTimeZone(
      run.hasSame(DateTime.now().setZone(tz), "day")
        ? $t`Next scheduled backup: today at ${time}`
        : $t`Next scheduled backup: tomorrow at ${time}`,
      tz,
    );
  });

  const settings = $derived([
    {
      icon: mdiImageMultiple,
      title: $t`Backup contents`,
      value: $t`Photos, videos, metadata, database, configuration, and external libraries.`,
    },
    {
      icon: mdiClock,
      title: $t`Schedule`,
      value: schedule,
      detail: nextBackup,
    },
    {
      icon: mdiDownloadBox,
      title: $t`Storage location`,
      value: storageLocation,
    },
  ]);

  const actions = $derived<OnboardingStepAction[]>([
    { label: $t`Start backup`, onClick: onStartBackup, loading },
  ]);
</script>

<OnboardingStepLayout
  description={$t`Immich has prepared recommended settings for your first backup. You can update these anytime from the Backups dashboard.`}
  {actions}
  badge={false}
>
  <Stack gap={6} class="bg-primary-50 rounded-2xl p-6">
    {#each settings as setting (setting.title)}
      <HStack gap={4}>
        <Icon
          icon={setting.icon}
          size="2.4rem"
          class="text-primary mt-1 shrink-0"
        />

        <Stack>
          <Text fontWeight="semi-bold">{setting.title}</Text>
          <Text>{setting.value}</Text>
          {#if setting.detail}
            <Text size="small" color="muted">{setting.detail}</Text>
          {/if}
        </Stack>
      </HStack>
    {/each}
  </Stack>
</OnboardingStepLayout>
