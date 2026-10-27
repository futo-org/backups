<script lang="ts">
  import BackupStatus, {
    type BackupStatusState,
    type BackupStatusType,
  } from "$lib/components/backups/BackupStatus.svelte";
  import OnEvents from "$lib/components/util/OnEvents.svelte";
  import {
    getRemainingText,
    handleCancelJob,
    jobKinds,
    useJob,
    useJobEventHandler,
  } from "$lib/services/job.service";
  import { formatDuration } from "$lib/utils/format";
  import {
    CloseButton,
    FormatBytes,
    Heading,
    HStack,
    Modal,
    ModalBody,
    ModalHeader,
    Scrollable,
    Stack,
    Text,
  } from "@immich/ui";
  import { DateTime } from "luxon";
  import { onDestroy } from "svelte";
  import { msg, plural, t } from "svelte-i18n-lingui";

  type Props = {
    jobId: string;
    onClose: () => void;
    onRetry?: () => void;
  };

  const { jobId, onClose, onRetry }: Props = $props();

  // svelte-ignore state_referenced_locally
  const jobQuery = useJob(jobId);
  const job = $derived(jobQuery.data);
  const { onJobUpdate, onJobTick } = useJobEventHandler();
  const summary = $derived(job?.outcome?.summary);

  let now = $state(DateTime.now());
  const tick = setInterval(() => (now = DateTime.now()), 1000);

  onDestroy(() => {
    clearInterval(tick);
  });

  const kind = $derived(job ? jobKinds[job.name] : "backup");
  const type: BackupStatusType = $derived(
    kind === "syncMetrics" ? "backup" : kind,
  );

  const backupState: BackupStatusState = $derived.by(() => {
    if (!job) {
      return "connecting";
    }

    switch (job.status) {
      case "queued":
      case "running": {
        return "running";
      }
      case "failed": {
        return "failed";
      }
      case "cancelled": {
        return "cancelled";
      }
      case "incomplete": {
        return "interrupted";
      }
      case "warn": {
        return "warned";
      }
      default: {
        return "complete";
      }
    }
  });

  const duration = $derived(
    job?.start
      ? formatDuration(
          (job.end ? DateTime.fromISO(job.end) : now).toMillis() -
            DateTime.fromISO(job.start).toMillis(),
          "long",
        )
      : "",
  );

  const titles: Record<BackupStatusType, Record<"running" | "done", string>> = {
    backup: { running: msg`Backing up your library`, done: msg`Backup` },
    restore: { running: msg`Restoring your library`, done: msg`Restore` },
    forget: { running: msg`Pruning old backups`, done: msg`Prune` },
  };

  const retry = $derived(
    onRetry
      ? () => {
          onClose();
          onRetry();
        }
      : undefined,
  );

  const title = $derived.by(() => {
    switch (backupState) {
      case "complete": {
        return $t({
          message: "{name} complete",
          values: { name: $t(titles[type].done) },
        });
      }
      case "warned": {
        return $t({
          message: "{name} completed with warnings",
          values: { name: $t(titles[type].done) },
        });
      }
      case "failed": {
        return $t({
          message: "{name} failed",
          values: { name: $t(titles[type].done) },
        });
      }
      case "cancelled": {
        return $t({
          message: "{name} cancelled",
          values: { name: $t(titles[type].done) },
        });
      }
      case "interrupted": {
        return $t({
          message: "{name} interrupted",
          values: { name: $t(titles[type].done) },
        });
      }
      default: {
        return $t(titles[type].running);
      }
    }
  });
</script>

<OnEvents {onJobUpdate} {onJobTick} />

<Modal
  size="medium"
  {onClose}
  // this is a bit of a hack to remove the frames from base modal...
  // this one might be removed ; twin code is in UpsellModal
  class="[&>div>div:first-child]:border-b-0 [&>div>div:first-child]:px-8 [&>div>div:first-child]:pb-0"
>
  <ModalHeader>
    <HStack fullWidth class="justify-end">
      <CloseButton onclick={onClose} />
    </HStack>
  </ModalHeader>

  <ModalBody class="px-8 pt-2 pb-8">
    <BackupStatus
      {title}
      {type}
      state={backupState}
      progress={job?.progress?.percentDone ?? (summary ? 1 : 0)}
      start={job?.start}
      {duration}
      remaining={getRemainingText(job?.progress)}
      errors={job?.outcome?.errors}
      currentFiles={job?.progress?.currentFiles}
      onRetry={retry}
      onCancel={job ? () => void handleCancelJob(job.id, type) : undefined}
    >
      {#snippet details()}
        {#if summary?.type === "backup"}
          {$t({
            message: "{count} items backed up",
            values: {
              count: summary.totalFilesProcessed.toLocaleString(),
            },
          })} &middot;
          {$t({
            message: "{count} new items",
            values: { count: summary.filesNew.toLocaleString() },
          })}
          &middot;
          <FormatBytes bytes={summary.totalBytesProcessed} /> {$t`processed`}
        {:else if summary?.type === "restore"}
          {$t({
            message: "{count} items restored",
            values: { count: summary.filesRestored.toLocaleString() },
          })}{#if summary.filesSkipped}
            &middot; {$t({
              message: "{count} skipped",
              values: { count: summary.filesSkipped.toLocaleString() },
            })}
          {/if}
          &middot; <FormatBytes bytes={summary.bytesRestored} /> {$t`restored`}
        {:else if summary?.type === "prune"}
          {$plural(summary.removed, {
            one: "# backup removed",
            other: "# backups removed",
          })} &middot;
          {$t({
            message: "{count} kept",
            values: { count: summary.kept.toLocaleString() },
          })}
        {/if}
      {/snippet}
    </BackupStatus>
  </ModalBody>
</Modal>
