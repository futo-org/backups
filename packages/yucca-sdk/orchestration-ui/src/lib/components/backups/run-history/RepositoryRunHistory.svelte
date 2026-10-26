<script lang="ts">
  import StackList from "$lib/components/ui/StackList.svelte";
  import StackListPlaceholder from "$lib/components/ui/StackListPlaceholder.svelte";
  import OnEvents from "$lib/components/util/OnEvents.svelte";
  import Suspense from "$lib/components/util/Suspense.svelte";
  import type { LocalRepositoryDto } from "$lib/fetch-client";
  import {
    useJobEventHandler,
    useJobs,
  } from "$lib/services/job.service";
  import { Button } from "@immich/ui";
  import RepositoryRunHistoryItem from "./RepositoryRunHistoryItem.svelte";
  import { t } from "svelte-i18n-lingui";

  type Props = {
    repository: LocalRepositoryDto;
    limit?: number;
    onViewAll?: () => void;
  };

  let { repository, limit = 5, onViewAll }: Props = $props();

  const query = useJobs(() => repository.id);
  const { onJobCreate, onJobUpdate } = useJobEventHandler();
</script>

<OnEvents {onJobCreate} {onJobUpdate} />

<StackList>
  {#snippet title()}
    {$t`Recent backup attempts`}
  {/snippet}

  {#snippet action()}
    {#if onViewAll && query.data?.length}
      <Button variant="ghost" size="small" onclick={onViewAll}>{$t`View all`}</Button>
    {/if}
  {/snippet}

  <Suspense {query}>
    {#snippet children(jobs)}
      {#each jobs.slice(0, limit) as job (job.id)}
        <RepositoryRunHistoryItem {job} />
      {/each}

      {#if jobs.length === 0}
        <StackListPlaceholder>{$t`No recent backups`}</StackListPlaceholder>
      {/if}
    {/snippet}
  </Suspense>
</StackList>
