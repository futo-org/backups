<script lang="ts">
  import RepositoryFormModal from "./RepositoryFormModal.svelte";

  type Props = {
    onClose: () => void;
  };

  let { onClose }: Props = $props();
</script>

<RepositoryFormModal {onClose} />
