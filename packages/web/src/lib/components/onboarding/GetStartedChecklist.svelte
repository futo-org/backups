<script lang="ts">
  import {
    RelativeTime,
    StackList,
    StackListItem,
  } from "@futo-org/backups-orchestrator-ui";
  import {
    Badge,
    Button,
    Code,
    HStack,
    Icon,
    Link,
    LoadingSpinner,
    Logo,
    Text,
  } from "@immich/ui";
  import { mdiCheck, mdiInformationOutline, mdiOpenInNew } from "@mdi/js";
  import { t } from "svelte-i18n-lingui";
  import type { OnboardingProgress } from "$lib/utils/onboarding";

  type Props = {
    progress: OnboardingProgress;
  };

  const { progress }: Props = $props();

  const setupGuideUrl = "https://docs.futo.cloud/getting-started/immich";
  const standaloneGuideUrl =
    "https://docs.futo.cloud/getting-started/standalone";
  const immichLinkUrl = "https://my.immich.app/link?target=backups";

  const completedSteps = $derived(progress.connected ? 3 : 0);

  const connectedOutsideImmich = $derived(
    !!progress.connectionType && progress.connectionType !== "immich",
  );
</script>

{#snippet stepIcon(step: number, done: boolean)}
  {#if done}
    <Icon icon={mdiCheck} />
  {:else}
    <span class="text-base font-semibold tabular-nums">{step}</span>
  {/if}
{/snippet}

<StackList>
  {#snippet title()}
    {$t`Get started`}
  {/snippet}

  {#snippet action()}
    <Badge size="small" color={progress.connected ? "success" : "secondary"}>
      {$t({
        message: "{done} of {total} done",
        values: { done: completedSteps, total: 4 },
      })}
    </Badge>
  {/snippet}

  <StackListItem
    stackOnMobile
    title={$t`Switch Immich to the beta build`}
    color={progress.connected ? "success" : "primary"}
  >
    {#snippet icon()}
      {@render stepIcon(1, progress.connected)}
    {/snippet}

    {#if connectedOutsideImmich}
      {$t`Not needed outside Immich`}
    {:else if progress.connected}
      {$t`Done`}
    {:else}
      {$t`This is a development build of Immich. Back up your Immich data first and don't use a server you can't afford to break.`}
      {$t`Set`}
      <Code>IMMICH_VERSION=pr-27817</Code>
      {$t`in your Immich .env, then pull and restart. You need to be an Immich admin.`}
    {/if}

    {#snippet trailing()}
      {#if !progress.connected}
        <Button
          href={setupGuideUrl}
          target="_blank"
          rel="noreferrer"
          size="small"
          variant="outline"
          trailingIcon={mdiOpenInNew}>{$t`Setup guide`}</Button
        >
      {/if}
    {/snippet}
  </StackListItem>

  <StackListItem
    stackOnMobile
    title={$t`Turn on backups in Immich`}
    color={progress.connected ? "success" : "primary"}
  >
    {#snippet icon()}
      {@render stepIcon(2, progress.connected)}
    {/snippet}

    {#if connectedOutsideImmich}
      {$t`Not needed outside Immich`}
    {:else if progress.connected}
      {$t`Done`}
    {:else}
      {$t`Open the Backups page on your Immich server to enable FUTO Backups.`}
    {/if}

    {#snippet trailing()}
      {#if !progress.connected}
        <Button
          href={immichLinkUrl}
          target="_blank"
          rel="noreferrer"
          size="small"
          variant="outline"
        >
          <Logo variant="icon" size="tiny" />
          {$t`Open in Immich`}
        </Button>
      {/if}
    {/snippet}
  </StackListItem>

  <StackListItem
    stackOnMobile
    title={$t`Connect your FUTO account`}
    color={progress.connected ? "success" : "primary"}
  >
    {#snippet icon()}
      {@render stepIcon(3, progress.connected)}
    {/snippet}

    {#if progress.connected && progress.connectionName}
      {$t({
        message: "{name} is connected",
        values: { name: progress.connectionName },
      })}
    {:else if progress.connected}
      {$t`Connected`}
    {:else}
      {$t`Approve the connection from Immich and save your recovery key. FUTO cannot recover a lost key.`}
    {/if}
  </StackListItem>

  <StackListItem
    stackOnMobile
    title={progress.firstBackup === "waiting"
      ? $t`Start your first backup`
      : $t`Your first backup`}
  >
    {#snippet icon()}
      {#if progress.firstBackup === "running"}
        <LoadingSpinner size="small" />
      {:else}
        {@render stepIcon(4, false)}
      {/if}
    {/snippet}

    {#if progress.firstBackup === "running" && progress.startedAt}
      {$t`Backing up, started`}
      <RelativeTime time={progress.startedAt} />.
      {$t`Large libraries can take a while.`}
    {:else if connectedOutsideImmich}
      {$t`Start it from the app you connected. It shows up here as soon as it starts.`}
    {:else if progress.connected}
      {$t`Start it from the Backups page in Immich. It shows up here as soon as it starts.`}
    {:else}
      {$t`It shows up here as soon as it starts.`}
    {/if}

    {#snippet trailing()}
      {#if progress.firstBackup === "running"}
        <Badge size="small" color="info">{$t`In progress`}</Badge>
      {/if}
    {/snippet}
  </StackListItem>

  <HStack gap={3} class="items-center bg-primary-50 px-5 py-3 text-primary">
    <Icon icon={mdiInformationOutline} class="shrink-0" />
    <Text size="small">
      {$t`Can't change your Immich image, or not using Immich?`}
      <Link href={standaloneGuideUrl} target="_blank" rel="noreferrer"
        >{$t`Use the standalone container instead`}</Link
      >
    </Text>
  </HStack>
</StackList>
