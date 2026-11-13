<script lang="ts">
  import ScheduleEditor from "$lib/components/schedules/ScheduleEditor.svelte";
  import Accordion from "$lib/components/ui/Accordion.svelte";
  import OnEvents from "$lib/components/util/OnEvents.svelte";
  import {
    useConfigureImmichIntegration,
    useIntegrationEventHandler,
    useIntegrations,
  } from "$lib/services/integrations.service";
  import {
    useRepositories,
    useRepositoryEventHandler,
  } from "$lib/services/repository.service";
  import {
    useScheduleEventHandler,
    useSchedules,
  } from "$lib/services/schedule.service";
  import { isValidCron } from "$lib/utils/cron";
  import {
    Button,
    Field,
    HStack,
    LoadingSpinner,
    Stack,
    Switch,
  } from "@immich/ui";
  import { mdiClockOutline } from "@mdi/js";
  import { t } from "svelte-i18n-lingui";

  const integrations = useIntegrations();
  const repositories = useRepositories();
  const schedules = useSchedules();
  const mutation = useConfigureImmichIntegration();

  const { onIntegrationUpdate } = useIntegrationEventHandler();
  const { onRepositoryCreate, onRepositoryUpdate, onRepositoryDelete } =
    useRepositoryEventHandler();
  const { onScheduleCreate, onScheduleUpdate, onScheduleDelete } =
    useScheduleEventHandler();

  const integration = $derived(integrations.data?.immichIntegration);

  const repository = $derived(
    integration
      ? repositories.data?.find((entry) => entry.id === integration.id)
      : undefined,
  );

  const schedule = $derived(
    integration
      ? schedules.data?.schedules.find((entry) => entry.id === integration.scheduleId)
      : undefined,
  );

  const isLoading = $derived(
    integrations.isLoading || repositories.isLoading || schedules.isLoading,
  );

  let cron = $state("0 3 * * *");
  let enabled = $state(true);
  let loaded = false;

  const load = () => {
    if (!schedule) {
      return;
    }

    cron = schedule.cron;
    enabled = !schedule.paused;
  };

  $effect(() => {
    if (loaded || !schedule) {
      return;
    }

    loaded = true;
    load();
  });

  const onSave = () => {
    if (!integration || !repository || !schedule || !isValidCron(cron)) {
      return;
    }

    mutation.mutate({
      name: repository.name,
      worm: repository.worm,
      dataFolders: integration.configuration.dataFolders,
      backupConfiguration: integration.configuration.backupConfiguration,
      libraries: integration.configuration.libraries,
      cron,
      paused: !enabled,
    });
  };
</script>

<OnEvents
  {onIntegrationUpdate}
  {onRepositoryCreate}
  {onRepositoryUpdate}
  {onRepositoryDelete}
  {onScheduleCreate}
  {onScheduleUpdate}
  {onScheduleDelete}
/>

<Accordion
  title={$t`Schedule`}
  subtitle={$t`Manage when backups run.`}
  icon={mdiClockOutline}
>
  <Stack gap={4} class="pt-2">
    {#if isLoading}
      <LoadingSpinner />
    {:else}
      <Field
        label={$t`Run backups automatically`}
        description={$t`Back up your library on a recurring schedule.`}
        color="primary"
      >
        <Switch bind:checked={enabled} />
      </Field>

      <ScheduleEditor bind:cron disabled={!enabled} />

      <HStack gap={2} class="justify-end">
        <Button
          shape="round"
          color="secondary"
          disabled={mutation.isPending}
          onclick={load}
        >
          {$t`Reset`}
        </Button>
        <Button
          shape="round"
          disabled={!isValidCron(cron)}
          loading={mutation.isPending}
          onclick={onSave}
        >
          {$t`Save`}
        </Button>
      </HStack>
    {/if}
  </Stack>
</Accordion>
