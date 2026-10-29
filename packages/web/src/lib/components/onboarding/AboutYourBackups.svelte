<script lang="ts">
  import { StackList, StackListItem } from "@futo-org/backups-orchestrator-ui";
  import type { MetaResponseDto } from "@futo-org/backups-api-client";
  import { Badge, Button, Icon } from "@immich/ui";
  import {
    mdiFlaskOutline,
    mdiHelpCircleOutline,
    mdiLockOutline,
    mdiMapMarkerOutline,
    mdiOpenInNew,
  } from "@mdi/js";
  import { t } from "svelte-i18n-lingui";

  type Props = {
    repositories: { siteCode: string | null }[];
    meta?: MetaResponseDto;
  };

  const { repositories, meta }: Props = $props();

  const siteDescriptions = $derived.by(() => {
    if (!meta) {
      return [];
    }

    const codes = new Set(
      repositories
        .map(({ siteCode }) => siteCode)
        .filter((code): code is string => !!code),
    );
    if (codes.size === 0) {
      codes.add(meta.default_site);
    }

    return meta.sites
      .filter((site) => codes.has(site.code))
      .map((site) => site.description || site.display_name);
  });
</script>

{#snippet learnMore(href: string)}
  <Button
    {href}
    target="_blank"
    rel="noreferrer"
    size="small"
    variant="ghost"
    trailingIcon={mdiOpenInNew}>{$t`Learn more`}</Button
  >
{/snippet}

<StackList>
  {#snippet title()}
    {$t`About your backups`}
  {/snippet}

  <StackListItem stackOnMobile title={$t`Stored in the EU`}>
    {#snippet icon()}
      <Icon icon={mdiMapMarkerOutline} />
    {/snippet}

    {#if siteDescriptions.length > 0}
      {siteDescriptions.join(", ")}, {$t`on hardware FUTO runs itself.`}
    {:else}
      {$t`On hardware FUTO runs itself.`}
    {/if}

    {#snippet trailing()}
      {@render learnMore(
        "https://docs.futo.cloud/guides/account#where-your-data-is-stored",
      )}
    {/snippet}
  </StackListItem>

  <StackListItem stackOnMobile title={$t`End-to-end encrypted`}>
    {#snippet icon()}
      <Icon icon={mdiLockOutline} />
    {/snippet}

    {$t`Encrypted on your machine before upload. FUTO can't read your backups, and can't recover your recovery key if you lose it.`}

    {#snippet trailing()}
      {@render learnMore("https://docs.futo.cloud/guides/recovery-key")}
    {/snippet}
  </StackListItem>

  <StackListItem stackOnMobile title={$t`Closed beta`} color="warning">
    {#snippet icon()}
      <Icon icon={mdiFlaskOutline} />
    {/snippet}

    {$t`Free during beta. Backup data may be deleted when the beta ends, so keep another copy of anything important.`}

    {#snippet trailing()}
      <Badge size="small" color="warning">{$t`Beta`}</Badge>
    {/snippet}
  </StackListItem>

  <StackListItem stackOnMobile title={$t`Need help?`}>
    {#snippet icon()}
      <Icon icon={mdiHelpCircleOutline} />
    {/snippet}

    {$t`Read the docs or ask for help in the FUTO Backups channels on the Immich Discord.`}

    {#snippet trailing()}
      <Button
        href="https://docs.futo.cloud"
        target="_blank"
        rel="noreferrer"
        size="small"
        variant="ghost"
        trailingIcon={mdiOpenInNew}>{$t`Docs`}</Button
      >
    {/snippet}
  </StackListItem>
</StackList>
