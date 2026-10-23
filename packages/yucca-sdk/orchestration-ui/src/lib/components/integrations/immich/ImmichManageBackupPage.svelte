<script lang="ts">
  import BackendsList from "$lib/components/backends/BackendsList.svelte";
  import BackupTaskMonitor from "$lib/components/backups/BackupTaskMonitor.svelte";
  import RepositoryRunHistory from "$lib/components/backups/run-history/RepositoryRunHistory.svelte";
  import RepositorySnapshotsList from "$lib/components/backups/snapshots-list/RepositorySnapshotsList.svelte";
  import PageLayout from "$lib/components/ui/PageLayout.svelte";
  import OnEvents from "$lib/components/util/OnEvents.svelte";
  import {
    getBackupPageActions,
    useImmichBackupStatus,
    useImmichBackupStatusEventHandler,
  } from "$lib/services/immich.integration.service";
  import { Alert, Button, Container, HStack, Stack, Text } from "@immich/ui";
  import ImmichDatabaseDumpAlert from "./ImmichDatabaseDumpAlert.svelte";
  import ImmichManageBackupOverview from "./ImmichManageBackupOverview.svelte";
  import { t } from "svelte-i18n-lingui";

  type Props = {
    onConfigure: () => void;
    onViewAttempts: () => void;
    onViewSnapshots: () => void;
  };

  const { onConfigure, onViewAttempts, onViewSnapshots }: Props = $props();

  const backup = useImmichBackupStatus();

  const { repository, schedule } = $derived(backup);

  const { ViewRecoveryKey, Configure } = $derived(
    getBackupPageActions(repository?.id, onConfigure, $t),
  );
</script>

<OnEvents {...useImmichBackupStatusEventHandler()} />
<BackupTaskMonitor />

<PageLayout title={$t`Backups`} actions={[ViewRecoveryKey, Configure]}>
  <Container size="medium" center>
    {#if repository && schedule}
      <Stack class="mt-4" gap={6}>
        <Alert color="info" title={$t`FUTO Backups is in closed beta`}>
          <Stack gap={3}>
            <Text size="small">
              {$t`This is an early version of FUTO Backups. The service may be reset and your backup data may be deleted when the beta ends. Please don't rely on it as your only backup.`}
            </Text>
            <HStack gap={2}>
              <Button
                href="https://github.com/futo-org/backups/issues"
                target="_blank"
                size="small"
                shape="round"
                color="primary"
              >
                {$t`Report An Issue`}
              </Button>
              <Button
                href="https://docs.futo.cloud/help/support"
                target="_blank"
                size="small"
                shape="round"
                variant="ghost"
              >
                {$t`Get Support`}
              </Button>
            </HStack>
          </Stack>
        </Alert>
        <ImmichDatabaseDumpAlert />
        <ImmichManageBackupOverview {repository} {schedule} status={backup.status} />
        <BackendsList {repository} />
        <RepositoryRunHistory {repository} onViewAll={onViewAttempts} />
        <RepositorySnapshotsList
          {repository}
          immich
          limit={5}
          onViewAll={onViewSnapshots}
        />
      </Stack>
    {/if}
  </Container>
</PageLayout>
