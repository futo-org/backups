<script lang="ts">
  import { useCreateSchedule } from "$lib/services/schedule.service";
  import { isValidCron } from "$lib/utils/cron";
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
    !isValidCron(cron) ||
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
    <ScheduleEditor bind:cron />

    <RepositoryPicker bind:repositories />
  </Stack>
</FormModal>
