<script lang="ts">
  import { goto } from "$app/navigation";
  import AboutYourBackups from "$lib/components/onboarding/AboutYourBackups.svelte";
  import GetStartedChecklist from "$lib/components/onboarding/GetStartedChecklist.svelte";
  import {
    useOnboardingConnections,
    useOnboardingRepositories,
  } from "$lib/services/onboarding.service";
  import { getOnboardingProgress } from "$lib/utils/onboarding";
  import { DashboardPage } from "@futo-org/backups-orchestrator-ui";

  const { data } = $props();

  // svelte-ignore state_referenced_locally
  const connections = useOnboardingConnections(data.connections);
  // svelte-ignore state_referenced_locally
  const repositories = useOnboardingRepositories(
    data.initialData.repositories.repositories,
  );

  const progress = $derived(
    getOnboardingProgress(connections.data, repositories.data),
  );

  const hasConnectedImmich = $derived(
    connections.data.some(
      ({ type, lastSeenAt }) => type === "immich" && !!lastSeenAt,
    ),
  );
</script>

<svelte:head><title>Overview &middot; FUTO Backups</title></svelte:head>

<DashboardPage
  initialData={data.initialData.repositories}
  onViewBackups={() => goto("/dashboard/backups")}
  showSetupLink={hasConnectedImmich}
  hideEmptySummary
>
  {#snippet intro()}
    {#if progress.firstBackup !== "complete"}
      <GetStartedChecklist {progress} />
    {/if}
  {/snippet}

  {#snippet outro()}
    <AboutYourBackups repositories={repositories.data} meta={data.meta} />
  {/snippet}
</DashboardPage>
