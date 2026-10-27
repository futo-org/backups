<script lang="ts">
  import OnEvents from "$lib/components/util/OnEvents.svelte";
  import {
    getRemainingText,
    useJob,
    useJobEventHandler,
  } from "$lib/services/job.service";
  import { now } from "$lib/utils/now";
  import { t } from "svelte-i18n-lingui";

  type Props = {
    jobId: string;
  };

  const { jobId }: Props = $props();

  // svelte-ignore state_referenced_locally
  const query = useJob(jobId);
  const progress = $derived(query.data?.progress);
  const { onJobUpdate, onJobTick } = useJobEventHandler();
</script>

<OnEvents {onJobUpdate} {onJobTick} />

{#if progress}
  {#if !progress.scanning}
    &middot;
    <span class="tabular-nums">{Math.round(progress.percentDone * 100)}%</span>
  {/if}
  &middot; {getRemainingText(progress, $now)}
{:else if query.data?.status === "queued"}
  &middot; {$t`Waiting to start`}
{:else}
  &middot; {$t`Preparing…`}
{/if}
