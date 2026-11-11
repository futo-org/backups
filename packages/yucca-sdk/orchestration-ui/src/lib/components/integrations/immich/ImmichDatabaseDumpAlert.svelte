<script lang="ts">
  import {
    useConfigureImmichDatabaseDump,
    useIgnoreImmichDatabaseDumpWarning,
    useImmichBackupStatus,
  } from "$lib/services/immich.integration.service";
  import { Alert, Button, HStack, Stack, Text } from "@immich/ui";
  import { t } from "svelte-i18n-lingui";

  const backup = useImmichBackupStatus();
  const configure = useConfigureImmichDatabaseDump();
  const ignore = useIgnoreImmichDatabaseDumpWarning();
</script>

{#if backup.needsAttention}
  <Alert color="warning" title={$t`Immich is also making database backups`}>
    <Stack gap={3}>
      <Text size="small">
        {$t`FUTO Backups makes a fresh database backup before every run, in the same folder as Immich's own nightly ones. Turning off Immich's nightly backups avoids doing the work twice. Your database backups still land in that folder, so any other backup you run of it keeps working.`}
      </Text>
      <HStack gap={2}>
        <Button
          size="small"
          color="primary"
          loading={configure.isPending}
          onclick={() => configure.mutate({ enabled: false })}
        >
          {$t`Turn off Immich's nightly backups`}
        </Button>
        <Button
          size="small"
          variant="ghost"
          loading={ignore.isPending}
          onclick={() => ignore.mutate()}
        >
          {$t`Keep both`}
        </Button>
      </HStack>
    </Stack>
  </Alert>
{/if}
