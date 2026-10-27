<script lang="ts">
  import {
    Button,
    HStack,
    Modal,
    ModalBody,
    ModalFooter,
    Text,
  } from "@immich/ui";
  import { t } from "svelte-i18n-lingui";

  type Props = {
    onClose: (confirmed: boolean) => void;
  };

  const { onClose }: Props = $props();
</script>

<Modal
  title={$t`Repository no longer on FUTO Backups`}
  size="small"
  onClose={() => onClose(false)}
>
  <ModalBody>
    <Text>
      {$t`This repository no longer exists on FUTO Backups. Remove it from this machine? Local settings (paths, schedules) will be removed; no backup data is affected.`}
    </Text>
  </ModalBody>
  <ModalFooter>
    <HStack>
      <Button color="danger" onclick={() => onClose(true)}>
        {$t`Remove from this machine`}
      </Button>
      <Button variant="ghost" onclick={() => onClose(false)}>
        {$t`Cancel`}
      </Button>
    </HStack>
  </ModalFooter>
</Modal>
