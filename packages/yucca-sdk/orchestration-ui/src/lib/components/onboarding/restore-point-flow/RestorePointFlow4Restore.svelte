<script lang="ts">
  import OnEvents from "$lib/components/util/OnEvents.svelte";
  import {
    getRemainingText,
    isJobFinished,
    useJob,
    useJobEventHandler,
    type JobUpdateEvent,
  } from "$lib/services/job.service";
  import { Alert, Modal, ModalBody, ProgressBar, Stack, Text } from "@immich/ui";
  import { t } from "svelte-i18n-lingui";

  type Props = {
    onFinish: () => void;

    jobId: string;
  };

  const { onFinish, jobId }: Props = $props();

  // svelte-ignore state_referenced_locally
  const jobQuery = useJob(jobId);
  const job = $derived(jobQuery.data);
  const progress = $derived(job?.progress?.percentDone ?? 0);
  const errors = $derived(job?.outcome?.errors ?? []);
  const currentFiles = $derived(jobQuery.data?.progress?.currentFiles ?? []);
  const jobEventHandler = useJobEventHandler();

  const onJobUpdate = (event: JobUpdateEvent) => {
    jobEventHandler.onJobUpdate(event);
    if (event.data.jobId === jobId && (event.data.job.status === "complete" || event.data.job.status === "warn")) {
      onFinish();
    }
  };
</script>

<OnEvents {onJobUpdate} onJobTick={jobEventHandler.onJobTick} />

<Modal focusOnOpen
  title={job?.status === "cancelled"
    ? $t`Restore cancelled`
    : errors.length > 0 || job?.status === "failed"
      ? $t`Restore failed`
      : $t`Restoring`}
  size="small"
  onClose={isJobFinished(job?.status) ? onFinish : undefined}
>
  <ModalBody>
    <Stack gap={2}>
      {#each errors as error}
        <Alert color="danger">{error}</Alert>
      {/each}

      <ProgressBar
        {progress}
        aria-label={$t`Restore progress`}
        valueLabel={`${Math.round(progress * 100)}%`}
        size="large"
      >
        <Text
          size="small"
          class={progress > 0.5 ? "text-light" : "text-dark"}
        >
          {getRemainingText(jobQuery.data?.progress)}
        </Text>
      </ProgressBar>

      {#if currentFiles.length > 0}
        <Stack gap={1}>
          {#each currentFiles as file}
            <Text size="tiny" class="break-all">{file}</Text>
          {/each}
        </Stack>
      {/if}
    </Stack>
  </ModalBody>
</Modal>
