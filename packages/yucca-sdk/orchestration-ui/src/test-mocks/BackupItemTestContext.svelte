<script lang="ts">
  import type { LocalRepositoryDto } from "$lib/fetch-client";
  import TestWrapper from "./TestContext.svelte";
  import BackupItem from "$lib/components/backups/BackupItem.svelte";

  const { repository }: { repository: LocalRepositoryDto } = $props();
</script>

<TestWrapper>
  <BackupItem {repository} />
</TestWrapper>
