<script lang="ts">
  import ListToolbar from "$lib/components/ui/ListToolbar.svelte";
  import Pagination from "$lib/components/ui/Pagination.svelte";
  import StackList from "$lib/components/ui/StackList.svelte";
  import StackListPlaceholder from "$lib/components/ui/StackListPlaceholder.svelte";
  import OnEvents from "$lib/components/util/OnEvents.svelte";
  import Suspense from "$lib/components/util/Suspense.svelte";
  import type { JobDto, LocalRepositoryDto } from "$lib/fetch-client";
  import {
    isJobFinished,
    useJobEventHandler,
    useJobs,
  } from "$lib/services/job.service";
  import { Stack, type ActionItem } from "@immich/ui";
  import { mdiRadioboxBlank, mdiRadioboxMarked } from "@mdi/js";
  import RepositoryRunHistoryItem from "./RepositoryRunHistoryItem.svelte";
  import { msg, t } from "svelte-i18n-lingui";

  type Props = {
    repository: LocalRepositoryDto;
    pageSize?: number;
  };

  let { repository, pageSize = 10 }: Props = $props();

  const query = useJobs(() => repository.id, "repository-backup");
  const { onJobCreate, onJobUpdate } = useJobEventHandler();

  let search = $state("");
  let newestFirst = $state(true);
  let status = $state<"all" | "complete" | "warn" | "failed" | "in-progress">(
    "all",
  );
  let page = $state(1);

  const onSearch = (value: string) => {
    search = value;
    page = 1;
  };

  const onFilter = (value: typeof status) => {
    status = value;
    page = 1;
  };

  const sortOptions = [
    { newest: true, title: msg`Newest first` },
    { newest: false, title: msg`Oldest first` },
  ];

  const statusOptions: { value: typeof status; title: string }[] = [
    { value: "all", title: msg`All attempts` },
    { value: "complete", title: msg`Successful only` },
    { value: "warn", title: msg`With warnings only` },
    { value: "failed", title: msg`Failed only` },
    { value: "in-progress", title: msg`In progress only` },
  ];

  const tick = (selected: boolean) =>
    selected ? mdiRadioboxMarked : mdiRadioboxBlank;

  const sort = $derived({
    label: newestFirst ? $t`Newest first` : $t`Oldest first`,
    items: sortOptions.map(
      (option): ActionItem => ({
        title: $t(option.title),
        icon: tick(newestFirst === option.newest),
        onAction: () => (newestFirst = option.newest),
      }),
    ),
  });

  const filters = $derived({
    label: $t(
      statusOptions.find((option) => option.value === status)?.title ??
        msg`Filters`,
    ),
    active: status !== "all",
    items: statusOptions.map(
      (option): ActionItem => ({
        title: $t(option.title),
        icon: tick(status === option.value),
        onAction: () => onFilter(option.value),
      }),
    ),
  });

  const matches = (job: JobDto) => {
    const term = search.trim().toLowerCase();

    if (!term) {
      return true;
    }

    return `${job.name} ${job.status}`.toLowerCase().includes(term);
  };

  const filtered = $derived(
    (query.data ?? [])
      .filter((job) => status === "all" || (status === "in-progress" ? !isJobFinished(job.status) : job.status === status))
      .filter(matches)
      .toSorted((a, b) =>
        newestFirst
          ? +new Date(b.queuedAt) - +new Date(a.queuedAt)
          : +new Date(a.queuedAt) - +new Date(b.queuedAt),
      ),
  );

  const pageCount = $derived(
    Math.max(Math.ceil(filtered.length / pageSize), 1),
  );
  const current = $derived(Math.min(page, pageCount));
  const visible = $derived(
    filtered.slice((current - 1) * pageSize, current * pageSize),
  );
</script>

<OnEvents {onJobCreate} {onJobUpdate} />

<Stack gap={4}>
  <ListToolbar
    placeholder={$t`Search backups`}
    {search}
    {onSearch}
    {sort}
    {filters}
  />

  <StackList>
    <Suspense {query}>
      {#each visible as job (job.id)}
        <RepositoryRunHistoryItem {job} />
      {/each}

      {#if filtered.length === 0}
        <StackListPlaceholder>{$t`No backups found`}</StackListPlaceholder>
      {/if}
    </Suspense>
  </StackList>

  <Pagination page={current} {pageCount} onChange={(next) => (page = next)} />
</Stack>
