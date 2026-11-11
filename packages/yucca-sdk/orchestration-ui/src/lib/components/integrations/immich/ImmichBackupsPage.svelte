<script lang="ts">
  import { Container } from "@immich/ui";
  import type { Snippet } from "svelte";
  import UpsellPage from "../../onboarding/upsell/UpsellPage.svelte";
  import ImmichManageBackupPage, {
    type BackupsPageLayout,
  } from "./ImmichManageBackupPage.svelte";
  import ImmichOnboardingSetupFlow from "./ImmichOnboardingSetupFlow.svelte";
  import ImmichResticMissingAlert from "./ImmichResticMissingAlert.svelte";

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
      <Container size="large" center>
        <ImmichResticMissingAlert class="mt-4" />
      </Container>
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
