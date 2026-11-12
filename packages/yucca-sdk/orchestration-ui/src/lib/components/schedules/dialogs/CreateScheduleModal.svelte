<script lang="ts">
  import { useCreateSchedule } from "$lib/services/schedule.service";
  import { Field, FormModal, Input, Stack } from "@immich/ui";
  import ScheduleEditor from "../ScheduleEditor.svelte";
  import RepositoryPicker from "../RepositoryPicker.svelte";
  import { t } from "svelte-i18n-lingui";

  type Props = {
    onClose: () => void;
  };

  const { onClose }: Props = $props();

  let name = $state("");
  let cron = $state("@daily");
  let repositories = $state<string[]>([]);

  let cronInvalid = $state(false);

  const mutation = useCreateSchedule();

  const onSubmit = () =>
    mutation.mutate(
      { name, cron, repositories },
      { onSuccess: () => onClose() },
    );
</script>

<FormModal
  title={$t`Create A New Schedule`}
  size="large"
  disabled={name.length === 0 ||
    cronInvalid ||
    repositories.length === 0 ||
    mutation.isPending}
  {onSubmit}
  {onClose}
>
  <Stack gap={4}>
    <Field
      label={$t`Name`}
      description={$t`Give this schedule a name`}
    >
      <Input bind:value={name} />
    </Field>
    <ScheduleEditor bind:cron bind:invalid={cronInvalid} />

    <RepositoryPicker bind:repositories />
  </Stack>
</FormModal>
