<script lang="ts">
  import { useImmichBackupStatus } from "$lib/services/immich.integration.service";
  import { Alert, Button, HStack, Stack, Text } from "@immich/ui";
  import { t } from "svelte-i18n-lingui";

  const { class: className }: { class?: string } = $props();

  const backup = useImmichBackupStatus();
</script>

{#if backup.resticMissing}
  <Alert
    color="danger"
    class={className}
    title={$t`Backups can't run on this Immich image`}
  >
    <Stack gap={3}>
      <Text size="small">
        {$t`FUTO Backups needs the restic program, and this Immich image does not include it. Switch to the official Immich image, or use the FUTO Backups standalone container.`}
      </Text>
      <HStack gap={2}>
        <Button
          href="https://docs.futo.cloud/getting-started/standalone"
          target="_blank"
          size="small"
          shape="round"
          color="primary"
        >
          {$t`Set up the standalone container`}
        </Button>
      </HStack>
    </Stack>
  </Alert>
{/if}
