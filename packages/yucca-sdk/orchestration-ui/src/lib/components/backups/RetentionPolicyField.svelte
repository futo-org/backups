<script lang="ts" module>
  import type { RetentionPolicyDto } from "$lib/fetch-client";
  import { msg } from "svelte-i18n-lingui";

  type RetentionChoice = {
    key: string;
    label: string;
    policy: RetentionPolicyDto | null;
  };

  const retentionChoices: RetentionChoice[] = [
    { key: "15d", label: msg`After 15 days`, policy: { keepWithin: "15d" } },
    { key: "30d", label: msg`After 30 days`, policy: { keepWithin: "30d" } },
    { key: "60d", label: msg`After 60 days`, policy: { keepWithin: "60d" } },
    { key: "90d", label: msg`After 90 days`, policy: { keepWithin: "90d" } },
    { key: "2", label: msg`Keep latest two backups`, policy: { keepLast: 2 } },
    { key: "never", label: msg`Never (keep all backups)`, policy: null },
  ];

  const defaultRetentionKey = "60d";

  export const defaultRetentionPolicy: RetentionPolicyDto = { keepWithin: "60d" };
</script>

<script lang="ts">
  import { Field, Select } from "@immich/ui";
  import { t } from "svelte-i18n-lingui";

  type Props = {
    policy: RetentionPolicyDto | null;
    disabled?: boolean;
  };

  let { policy = $bindable(), disabled = false }: Props = $props();

  const key = $derived(
    disabled
      ? "never"
      : (retentionChoices.find(
          (choice) => JSON.stringify(choice.policy) === JSON.stringify(policy),
        )?.key ?? defaultRetentionKey),
  );
</script>

<Field
  label={$t`Delete old backups`}
  description={$t`Older snapshots are pruned automatically.`}
  {disabled}
>
  <Select
    options={retentionChoices.map(({ key, label }) => ({
      value: key,
      label: $t(label),
    }))}
    value={key}
    onChange={(value) =>
      (policy =
        retentionChoices.find((choice) => choice.key === value)?.policy ?? null)}
  />
</Field>
