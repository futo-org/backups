<script lang="ts">
  import type { Snippet } from "svelte";
  import UpsellPage from "../../onboarding/upsell/UpsellPage.svelte";
  import ImmichManageBackupPage, {
    type BackupsPageLayout,
  } from "./ImmichManageBackupPage.svelte";
  import ImmichOnboardingSetupFlow from "./ImmichOnboardingSetupFlow.svelte";

  type Question = {
    title: string;
    answer: string | Snippet;
  };

  type Props = {
    questions: Question[];
    layout: BackupsPageLayout;
    onConfigure: () => void;
    onViewAttempts: () => void;
    onViewSnapshots: () => void;
  };

  const {
    questions,
    layout,
    onConfigure,
    onViewAttempts,
    onViewSnapshots,
  }: Props = $props();
</script>

<ImmichOnboardingSetupFlow>
  {#snippet fallback(onStart)}
    {#snippet upsell()}
      <UpsellPage {questions} onGetStarted={onStart} />
    {/snippet}

    {@render layout({ actions: [], children: upsell })}
  {/snippet}

  <ImmichManageBackupPage
    {layout}
    {onConfigure}
    {onViewAttempts}
    {onViewSnapshots}
  />
</ImmichOnboardingSetupFlow>
