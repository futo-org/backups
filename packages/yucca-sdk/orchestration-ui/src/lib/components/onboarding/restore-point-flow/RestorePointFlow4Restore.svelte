<script lang="ts">
  import OnEvents from "$lib/components/util/OnEvents.svelte";
  import {
    isJobFinished,
    useJob,
    useJobEventHandler,
    type JobUpdateEvent,
  } from "$lib/services/job.service";
  import { createLogObserver } from "$lib/services/log.service.svelte";
  import { Alert, Modal, ModalBody, ProgressBar, Stack, Text } from "@immich/ui";
  import { onDestroy } from "svelte";
  import { t } from "svelte-i18n-lingui";

  type Props = {
    onFinish: () => void;

    jobId: string;
  };

  const { onFinish, jobId }: Props = $props();

  // svelte-ignore state_referenced_locally
  const log = createLogObserver(jobId);
  onDestroy(() => log.destroy());
  // svelte-ignore state_referenced_locally
  const jobQuery = useJob(jobId);
  const errors = $derived(jobQuery.data?.outcome?.errors ?? []);
  const jobEventHandler = useJobEventHandler();

  const onJobUpdate = (event: JobUpdateEvent) => {
    jobEventHandler.onJobUpdate(event);
    if (
      event.data.jobId === jobId &&
      isJobFinished(event.data.job.status) &&
      !event.data.job.outcome?.errors.length
    ) {
      onFinish();
    }
  };
</script>

<OnEvents {onJobUpdate} />

<Modal focusOnOpen
  title={errors.length > 0 ? $t`Restore failed` : $t`Restoring`}
  size="small"
  onClose={errors.length > 0 ? onFinish : undefined}
>
  <ModalBody>
    <Stack gap={2}>
      {#each errors as error}
        <Alert color="danger">{error}</Alert>
      {/each}

      <ProgressBar
        progress={log.status.progress}
        aria-label={$t`Restore progress`}
        valueLabel={`${Math.round(log.status.progress * 100)}%`}
        size="large"
      >
        <Text
          size="small"
          class={log.status.progress > 0.5 ? "text-light" : "text-dark"}
        >
          {log.status.text}
        </Text>
      </ProgressBar>

      {#if log.status.currentFiles.length > 0}
        <Stack gap={1}>
          {#each log.status.currentFiles as file}
            <Text size="tiny" class="break-all">{file}</Text>
          {/each}
        </Stack>
      {/if}
    </Stack>
  </ModalBody>
</Modal>
