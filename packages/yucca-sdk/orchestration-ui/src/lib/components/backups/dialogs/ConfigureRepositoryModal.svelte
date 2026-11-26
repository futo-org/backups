<script lang="ts">
  import type { LocalRepositoryDto } from "$lib/fetch-client";
  import RepositoryFormModal from "./RepositoryFormModal.svelte";

  type Props = {
    repository: LocalRepositoryDto;
    onClose: () => void;
  };

  let { repository, onClose }: Props = $props();
</script>

<RepositoryFormModal {repository} {onClose} />
