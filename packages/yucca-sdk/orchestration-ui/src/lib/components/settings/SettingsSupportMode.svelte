<script lang="ts">
  import Accordion from "$lib/components/ui/Accordion.svelte";
  import OnEvents from "$lib/components/util/OnEvents.svelte";
  import {
    maxSupportModeRuns,
    refreshSupportMode,
    useSupportMode,
    useUpdateSupportMode,
  } from "$lib/services/supportMode.service";
  import {
    Button,
    Field,
    HStack,
    LoadingSpinner,
    NumberInput,
    Stack,
    Switch,
    Text,
  } from "@immich/ui";
  import { mdiLifebuoy } from "@mdi/js";
  import { nextRunsDraft, toRunsDraft } from "$lib/utils/supportMode";
  import { plural, t } from "svelte-i18n-lingui";
  import { untrack } from "svelte";

  const supportMode = useSupportMode();
  const mutation = useUpdateSupportMode();

  let runs = $state<number>();
  let streamToFuto = $state(false);
  let includePaths = $state(false);
  let loaded = false;
  let syncedRuns: number | undefined;

  const load = () => {
    if (!supportMode.data) {
      return;
    }

    runs = syncedRuns = toRunsDraft(supportMode.data.remainingRuns);
    streamToFuto = supportMode.data.streamToFuto;
    includePaths = supportMode.data.includePaths;
  };

  $effect(() => {
    const data = supportMode.data;
    if (!data) {
      return;
    }

    if (!loaded) {
      loaded = true;
      untrack(load);
      return;
    }

    runs = nextRunsDraft(
      untrack(() => runs),
      syncedRuns,
      data.remainingRuns,
    );
    syncedRuns = toRunsDraft(data.remainingRuns);
  });

  const streamingAvailable = $derived(
    supportMode.data?.streamingAvailable ?? false,
  );
  const remainingRuns = $derived(supportMode.data?.remainingRuns ?? 0);

  const onSave = () => {
    mutation.mutate({
      remainingRuns: Math.min(
        maxSupportModeRuns,
        Math.max(0, Math.floor(runs ?? 0)),
      ),
      streamToFuto: streamingAvailable && streamToFuto,
      includePaths: streamingAvailable && streamToFuto && includePaths,
    });
  };
</script>

<OnEvents onJobUpdate={refreshSupportMode} />

<Accordion
  title={$t`Support mode`}
  subtitle={$t`Record detailed logs to help FUTO support look into a problem.`}
  icon={mdiLifebuoy}
>
  <Stack gap={4} class="pt-2">
    {#if supportMode.isLoading}
      <LoadingSpinner />
    {:else}
      <div aria-live="polite">
        <Text size="small" color="muted">
          {#if remainingRuns > 0}
            {$plural(remainingRuns, {
              one: "Support mode is on for the next run.",
              other: "Support mode is on for the next # runs.",
            })}
          {:else}
            {$t`Support mode is off.`}
          {/if}
        </Text>
      </div>

      <Field
        label={$t`Runs in support mode`}
        description={$t`The next backups, cleanups and restores record detailed logs, which you can download from their history. Support mode turns itself off once they have run.`}
        color="primary"
      >
        <NumberInput
          bind:value={runs}
          min={0}
          max={maxSupportModeRuns}
          step={1}
          placeholder={$t`Off`}
        />
      </Field>

      {#if streamingAvailable}
        <Field
          label={$t`Send logs to FUTO`}
          description={$t`Stream the detailed logs to FUTO while each run happens, so support can read them. Runs with a lot of files produce a lot of logs.`}
          color="primary"
        >
          <Switch bind:checked={streamToFuto} />
        </Field>

        {#if streamToFuto}
          <Field
            label={$t`Include file names`}
            description={$t`Send file and folder names as they are. When off, they are replaced with placeholders before they leave this server.`}
            color="primary"
          >
            <Switch bind:checked={includePaths} />
          </Field>
        {/if}
      {/if}

      <HStack gap={2} class="justify-end">
        <Button
          shape="round"
          color="secondary"
          disabled={mutation.isPending}
          onclick={load}
        >
          {$t`Reset`}
        </Button>
        <Button shape="round" loading={mutation.isPending} onclick={onSave}>
          {$t`Save`}
        </Button>
      </HStack>
    {/if}
  </Stack>
</Accordion>
