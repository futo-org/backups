<script lang="ts">
  import StackListItem from "$lib/components/ui/StackListItem.svelte";
  import RelativeTime from "$lib/components/util/RelativeTime.svelte";
  import type { JobDto } from "$lib/fetch-client";
  import { getJobActions, jobKinds } from "$lib/services/job.service";
  import { Icon } from "@immich/ui";
  import {
    mdiCloudCheckOutline,
    mdiCloudOffOutline,
    mdiCloudSyncOutline,
  } from "@mdi/js";
  import { t, msg } from "svelte-i18n-lingui";

  type Props = {
    job: JobDto;
  };

  const { job }: Props = $props();
  const { ViewLog, DownloadLog } = $derived(getJobActions(job, $t));

  const nouns = {
    restore: {
      name: msg`restore`,
      running: msg`Restore`,
      done: msg`Restored`,
    },
    forget: { name: msg`prune`, running: msg`Prune`, done: msg`Pruned` },
    backup: { name: msg`backup`, running: msg`Backup`, done: msg`Backed up` },
    syncMetrics: {
      name: msg`metrics sync`,
      running: msg`Metrics sync`,
      done: msg`Metrics synced`,
    },
  };

  const noun = $derived(nouns[jobKinds[job.name]]);

  const status = $derived.by(() => {
    switch (job.status) {
      case "failed": {
        return {
          title: $t({
            message: "Failed {noun}",
            values: { noun: $t(noun.name) },
          }),
          color: "danger",
          icon: mdiCloudOffOutline,
        } as const;
      }
      case "cancelled": {
        return {
          title: $t({
            message: "Cancelled {noun}",
            values: { noun: $t(noun.name) },
          }),
          color: "warning",
          icon: mdiCloudOffOutline,
        } as const;
      }
      case "warn": {
        return {
          title: $t({
            message: "{done} with warnings",
            values: { done: $t(noun.done) },
          }),
          color: "warning",
          icon: mdiCloudCheckOutline,
        } as const;
      }
      case "queued": {
        return {
          title: $t({
            message: "{running} queued",
            values: { running: $t(noun.running) },
          }),
          color: "primary",
          icon: mdiCloudSyncOutline,
        } as const;
      }
      case "running": {
        return {
          title: $t({
            message: "{running} in progress",
            values: { running: $t(noun.running) },
          }),
          color: "primary",
          icon: mdiCloudSyncOutline,
        } as const;
      }
      default: {
        return {
          title: $t({
            message: "Successful {noun}",
            values: { noun: $t(noun.name) },
          }),
          color: "success",
          icon: mdiCloudCheckOutline,
        } as const;
      }
    }
  });
</script>

<StackListItem title={status.title} color={status.color} actions={[ViewLog, DownloadLog]}>
  {#snippet icon()}
    <Icon icon={status.icon} />
  {/snippet}

  {#if job.status === "queued"}
    {$t`Queued`} <RelativeTime time={job.queuedAt} />
  {:else if job.status === "running"}
    {$t`Started`} <RelativeTime time={job.start ?? job.queuedAt} />
  {:else if job.status === "failed" || job.status === "cancelled"}
    {$t`Attempted`} {#if job.end}<RelativeTime time={job.end} />{/if}
  {:else}
    {$t(noun.done)} {#if job.end}<RelativeTime time={job.end} />{/if}
  {/if}
</StackListItem>
