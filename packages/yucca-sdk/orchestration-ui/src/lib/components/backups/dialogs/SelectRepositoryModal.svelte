<script lang="ts">
  import StackList from "$lib/components/ui/StackList.svelte";
  import StackListOption from "$lib/components/ui/StackListOption.svelte";
  import StackListPlaceholder from "$lib/components/ui/StackListPlaceholder.svelte";
  import Suspense from "$lib/components/util/Suspense.svelte";
  import { useInspectRepositories } from "$lib/services/repository.service";
  import {
    isRestorable,
    latestSnapshot,
    sortRestoreCandidates,
  } from "$lib/utils/repository";
  import {
    Button,
    FormatBytes,
    HStack,
    Modal,
    ModalBody,
    ModalFooter,
    Stack,
  } from "@immich/ui";
  import { DateTime } from "luxon";
  import type { Snippet } from "svelte";
  import { plural, t } from "svelte-i18n-lingui";

  type Props = {
    title?: string;
    backendId?: string;

    leadingContent?: Snippet;
    footerContent?: Snippet;

    onSelect: (repositoryId: string) => void;
    onCancel: () => void;
  };

  const {
    title,
    backendId,
    leadingContent,
    footerContent,
    onSelect,
    onCancel,
  }: Props = $props();

  // svelte-ignore state_referenced_locally
  const query = useInspectRepositories(backendId);

  const sortedRepositories = $derived(sortRestoreCandidates(query.data ?? []));
</script>

<Modal title={title ?? $t`Select Backup`} size="small" onClose={onCancel}>
  <ModalBody>
    <Stack>
      {@render leadingContent?.()}

      <StackList>
        <Suspense {query}>
          {#each sortedRepositories as repository (repository.id)}
            {@const snapshots = repository.snapshots ?? []}
            {@const latest = latestSnapshot(snapshots)}

            <StackListOption
              title={repository.name}
              disabled={!isRestorable(repository)}
              onclick={() => onSelect(repository.id)}
            >
              {#if repository.snapshots === undefined}
                {$t`Can't access, is your recovery key correct?`}
              {:else if latest}
                {$t({
                  message: "Last backup: {date}",
                  values: {
                    date: DateTime.fromISO(latest.time).toLocaleString(
                      DateTime.DATETIME_MED,
                    ),
                  },
                })}
              {:else}
                {$t`No backups yet`}
              {/if}

              <span class="block">
                {#if latest}
                  {$plural(snapshots.length, {
                    one: "# backup",
                    other: "# backups",
                  })}
                  {#if latest.summary}
                    &middot; <FormatBytes bytes={latest.summary.totalBytes} />
                  {/if}
                  &middot;
                {/if}
                {$t({
                  message: "ID {id}",
                  values: { id: repository.id.slice(0, 8) },
                })}
              </span>
            </StackListOption>
          {/each}

          {#if sortedRepositories.length === 0}
            <StackListPlaceholder>{$t`No backups found.`}</StackListPlaceholder>
          {/if}
        </Suspense>
      </StackList>
    </Stack>
  </ModalBody>
  <ModalFooter>
    <HStack>
      <Button variant="ghost" onclick={onCancel}>{$t`Cancel`}</Button>
      {@render footerContent?.()}
    </HStack>
  </ModalFooter>
</Modal>
