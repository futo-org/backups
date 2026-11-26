<script lang="ts">
  import BackendsList from "$lib/components/backends/BackendsList.svelte";
  import PathListField from "$lib/components/ui/PathListField.svelte";
  import type { LocalRepositoryDto } from "$lib/fetch-client";
  import {
    useCreateRepository,
    useUpdateRepository,
  } from "$lib/services/repository.service";
  import { Checkbox, Field, FormModal, Input, Stack, Text } from "@immich/ui";
  import { SvelteSet } from "svelte/reactivity";
  import { t } from "svelte-i18n-lingui";

  type Props = {
    repository?: LocalRepositoryDto;
    onClose: () => void;
  };

  let { repository, onClose }: Props = $props();

  // svelte-ignore state_referenced_locally
  let name = $state(repository?.name ?? "");
  let worm = $state(false);
  // svelte-ignore state_referenced_locally
  const paths = new SvelteSet(repository?.configuration?.paths ?? []);
  let submitted = $state(false);

  const local = $derived(
    !repository || typeof repository.configuration === "object",
  );
  const createMutation = useCreateRepository();
  const updateMutation = useUpdateRepository();
  const pending = $derived(
    createMutation.isPending || updateMutation.isPending,
  );

  const onSubmit = () => {
    if (pending) return;
    submitted = true;
    if (!name.trim() || (!repository && paths.size === 0)) return;

    if (repository) {
      updateMutation.mutate(
        { id: repository.id, dto: { name, paths: [...paths] }, local },
        { onSuccess: onClose },
      );
    } else {
      createMutation.mutate(
        { name, worm, paths: [...paths] },
        { onSuccess: onClose },
      );
    }
  };
</script>

<FormModal
  title={repository
    ? $t({ message: "Configure {name}", values: { name } })
    : $t`Create A New Backup`}
  size="large"
  disabled={pending}
  {onSubmit}
  {onClose}
>
  <Stack gap={4}>
    <Field
      label={$t`Name`}
      description={repository
        ? undefined
        : $t`A memorable name for this backup`}
      invalid={submitted && !name.trim()}
    >
      <Input
        bind:value={name}
        disabled={pending}
        aria-invalid={submitted && !name.trim()}
      />
    </Field>
    {#if submitted && !name.trim()}
      <Text role="alert" color="danger" size="small">
        {$t`Enter a name for this backup`}
      </Text>
    {/if}

    {#if !repository}
      <Field
        label={$t`Write once (WORM)`}
        description={$t`Prevent anything being deleted`}
      >
        <Checkbox
          bind:checked={worm}
          disabled={pending}
          aria-label={$t`Write once (WORM)`}
        />
      </Field>
    {/if}

    {#if local}
      <fieldset disabled={pending} class="min-w-0">
        <legend class="text-sm font-medium">{$t`Backup Paths`}</legend>
        <Text color="secondary" size="small" class="mt-1 mb-2">
          {$t`Select files and folders to include in this backup.`}
        </Text>
        <PathListField
          {paths}
          addLabel={$t`Add path`}
          manageLabel={$t`Add first path`}
          pickerTitle={$t`Backup Paths`}
          pickerDescription={$t`Select files and folders to include in this backup.`}
        />
      </fieldset>
      {#if submitted && !repository && paths.size === 0}
        <Text role="alert" color="danger" size="small">
          {$t`Select at least one backup path`}
        </Text>
      {/if}
    {/if}

    {#if repository}
      <BackendsList {repository} />
    {/if}
  </Stack>
</FormModal>
