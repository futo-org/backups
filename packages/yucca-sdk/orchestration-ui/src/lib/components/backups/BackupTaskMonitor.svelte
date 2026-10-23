<script lang="ts">
  import OnEvents from "$lib/components/util/OnEvents.svelte";
  import { useBackupJobMonitor } from "$lib/services/job.service";
</script>

<OnEvents {...useBackupJobMonitor()} />
