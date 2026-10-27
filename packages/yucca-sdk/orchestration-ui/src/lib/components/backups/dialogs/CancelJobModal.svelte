<script lang="ts">
  import type { BackupStatusType } from "$lib/components/backups/BackupStatus.svelte";
  import {
    Button,
    HStack,
    Modal,
    ModalBody,
    ModalFooter,
    Text,
  } from "@immich/ui";
  import { msg, t } from "svelte-i18n-lingui";

  type Props = {
    type: BackupStatusType;
    onClose: (confirmed: boolean) => void;
  };

  const { type, onClose }: Props = $props();

  const titles: Record<BackupStatusType, string> = {
    backup: msg`Cancel this backup?`,
    restore: msg`Cancel this restore?`,
    forget: msg`Cancel this prune?`,
  };

  const prompts: Record<BackupStatusType, string> = {
    backup: msg`Progress since the last snapshot will be lost.`,
    restore: msg`The restore will stop and will need to be started again.`,
    forget: msg`Pruning will stop and will need to be started again.`,
  };

  const confirmLabels: Record<BackupStatusType, string> = {
    backup: msg`Cancel backup`,
    restore: msg`Cancel restore`,
    forget: msg`Cancel prune`,
  };

  const dismissLabels: Record<BackupStatusType, string> = {
    backup: msg`Keep backing up`,
    restore: msg`Keep restoring`,
    forget: msg`Keep pruning`,
  };
</script>

<Modal title={$t(titles[type])} size="small" onClose={() => onClose(false)}>
  <ModalBody>
    <Text>{$t(prompts[type])}</Text>
  </ModalBody>
  <ModalFooter>
    <HStack>
      <Button color="danger" onclick={() => onClose(true)}>
        {$t(confirmLabels[type])}
      </Button>
      <Button variant="ghost" onclick={() => onClose(false)}>
        {$t(dismissLabels[type])}
      </Button>
    </HStack>
  </ModalFooter>
</Modal>
