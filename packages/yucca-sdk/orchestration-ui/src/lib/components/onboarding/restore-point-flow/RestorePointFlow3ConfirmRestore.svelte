<script lang="ts">
  import type {
    InspectedLocalRepositoryDto,
    SnapshotDto,
  } from "$lib/fetch-client";
  import { handleRestoreFromPoint } from "$lib/services/snapshot.service";
  import {
    Button,
    Checkbox,
    Field,
    HStack,
    Modal,
    ModalBody,
    ModalFooter,
    Select,
    Stack,
    Text,
  } from "@immich/ui";
  import { tick } from "svelte";
  import { SvelteSet } from "svelte/reactivity";
  import { t } from "svelte-i18n-lingui";

  type Props = {
    onBack: () => void;
    onRestore: (jobId: string) => void;

    repository: InspectedLocalRepositoryDto;
    restoreEverything: boolean;
    snapshot: SnapshotDto;
  };

  const { onBack, onRestore, repository, restoreEverything, snapshot }: Props = $props();
  const backupIncludesId = $props.id();
  let yuccaConfigField: HTMLElement | undefined = $state();

  const clearYuccaConfig = async () => {
    yuccaConfig = undefined;
    await tick();
    yuccaConfigField?.querySelector("button")?.focus();
  };

  const yuccaConfigOptions = $derived(
    snapshot.paths
      .filter((path) => path.includes("yucca"))
      .map((value) => ({
        value,
        label: value,
      })),
  );

  // svelte-ignore state_referenced_locally
  let yuccaConfig: string | undefined = $state(
    snapshot.paths.find((path) => path.includes("yucca")),
  );

  // svelte-ignore state_referenced_locally
  let includePaths = new SvelteSet<string>(
    snapshot.paths.filter((path) => !path.includes("yucca")),
  );

  let starting = $state(false);

  async function handleRestore() {
    starting = true;
    const response = await handleRestoreFromPoint(
      repository.id,
      snapshot.id,
      repository.backends!.primary.id,
      {
        yuccaConfig,
        include: [...includePaths].filter((path) => path !== yuccaConfig),
      },
    );
    starting = false;

    if (response) {
      onRestore(response.jobId);
    }
  }
</script>

<Modal focusOnOpen title={$t`Confirm restore from snapshot`} size="small" onClose={onBack}>
  <ModalBody>
    <Stack>
      {#if restoreEverything}
        <Text>
          {$t`Restoring replaces your current Immich database, files and backup settings with this snapshot.`}
        </Text>
      {:else}
        <Field label={$t`Restore configuration`}>
          <HStack class="items-end">
            <div bind:this={yuccaConfigField} class="flex-1">
              <Select
                options={yuccaConfigOptions}
                bind:value={yuccaConfig}
                placeholder={$t`Not restoring backup configuration`}
              />
            </div>
            {#if yuccaConfig}
              <Button variant="ghost" onclick={clearYuccaConfig}>
                {$t`Clear`}
              </Button>
            {/if}
          </HStack>
        </Field>

        <div role="group" aria-labelledby={backupIncludesId} class="flex flex-col gap-2">
          <Text id={backupIncludesId} fontWeight="bold">{$t`Backup includes`}</Text>
          {#each snapshot.paths as path}
            {@const forced = path === yuccaConfig}
            <label class="select-none flex gap-2 items-center">
              <Checkbox
                checked={forced || includePaths.has(path)}
                disabled={forced}
                onCheckedChange={() =>
                  includePaths.has(path)
                    ? includePaths.delete(path)
                    : includePaths.add(path)}
              />
              {path}
            </label>
          {/each}
        </div>
      {/if}

      <Text size="small" color="muted">
        {$t`Files will be restored to their exact paths.`}
      </Text>
    </Stack>
  </ModalBody>
  <ModalFooter>
    <HStack>
      <Button variant="ghost" onclick={onBack}>{$t`Back`}</Button>
      <Button onclick={handleRestore} disabled={starting}>{$t`Restore`}</Button>
    </HStack>
  </ModalFooter>
</Modal>
