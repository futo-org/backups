<script lang="ts">
  import { Checkbox, HStack, Icon, Stack, Text } from "@immich/ui";
  import frameBugSvg from "@material-symbols/svg-400/outlined/frame_bug-fill.svg?raw";
  import hourglassTopSvg from "@material-symbols/svg-400/outlined/hourglass_top-fill.svg?raw";
  import percentDiscountSvg from "@material-symbols/svg-400/outlined/percent_discount-fill.svg?raw";
  import warningSvg from "@material-symbols/svg-400/outlined/warning-fill.svg?raw";
  import { toIconPath } from "$lib/utils/icon";
  import OnboardingStepLayout, {
    type OnboardingStepAction,
  } from "./OnboardingStepLayout.svelte";
  import { t } from "svelte-i18n-lingui";

  type Props = {
    onConfirm: () => void;
    loading?: boolean;
  };

  const { onConfirm, loading = false }: Props = $props();

  let confirm = $state(false);

  const notices = $derived([
    {
      icon: toIconPath(hourglassTopSvg),
      title: $t`Temporary beta access`,
      value: $t`Access to the service will end when the beta concludes and will be available again at launch.`,
    },
    {
      icon: toIconPath(percentDiscountSvg),
      title: $t`Free during closed beta`,
      value: $t`FUTO Backups is free during the closed beta. You won't be charged for any usage.`,
    },
    {
      icon: toIconPath(warningSvg),
      title: $t`Your backup data may be deleted`,
      value: $t`The service may be reset and your backup data may be deleted when the beta ends.`,
    },
    {
      icon: toIconPath(frameBugSvg),
      title: $t`Report issues`,
      value: $t`Found a bug? Let us know through Discord or the public GitHub issue tracker.`,
    },
  ]);

  const actions = $derived<OnboardingStepAction[]>([
    {
      label: $t`Start backup`,
      onClick: onConfirm,
      disabled: !confirm,
      loading,
    },
  ]);
</script>

<OnboardingStepLayout
  description={$t`Before continuing, please be aware of the following:`}
  {actions}
  badge={false}
>
  <Stack gap={4}>
    <Stack gap={6} class="bg-primary-50 rounded-2xl p-6">
      {#each notices as notice (notice.title)}
        <HStack gap={4}>
          <Icon
            icon={notice.icon}
            viewBox="0 -960 960 960"
            size="2.4rem"
            class="text-primary mt-1 shrink-0"
          />

          <Stack>
            <Text fontWeight="semi-bold">{notice.title}</Text>
            <Text>{notice.value}</Text>
          </Stack>
        </HStack>
      {/each}
    </Stack>

    <HStack gap={3} class="items-center">
      <Checkbox bind:checked={confirm} id="beta-disclaimer-understood" />
      <Text size="small">
        <label for="beta-disclaimer-understood">
          {$t`I understand my beta backups may be deleted.`}
        </label>
      </Text>
    </HStack>
  </Stack>
</OnboardingStepLayout>
