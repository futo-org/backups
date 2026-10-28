<script lang="ts">
  import {
    billingKeys,
    useBillingStatements,
    useBillingStatus,
    useStartSubscription,
    useSubscriptionPortal,
  } from "$lib/services/billing.service";
  import { getBillingStatus } from "@futo-org/backups-api-client";
  import { queryClient } from "@futo-org/backups-orchestrator-ui";
  import { Suspense } from "@futo-org/backups-orchestrator-ui";
  import type { BillingStatusDto } from "@futo-org/backups-api-client";
  import {
    Alert,
    Button,
    Card,
    CardBody,
    CardFooter,
    CardHeader,
    CardTitle,
    Heading,
    Stack,
    Text,
  } from "@immich/ui";
  import { mdiCreditCardOutline, mdiOpenInNew } from "@mdi/js";
  import { t } from "svelte-i18n-lingui";

  const { data } = $props();

  // svelte-ignore state_referenced_locally
  const status = useBillingStatus(data.initialData);
  const statements = useBillingStatements();
  const subscribe = useStartSubscription();
  const portal = useSubscriptionPortal();

  // Just back from a checkout or from Pay's billing page: a payment may be
  // settling. Pay learns of it from Polar's webhook a few seconds later and
  // notifies yucca, so while the status is one a payment resolves (not yet
  // subscribed, or a failed charge) ask Pay directly every few seconds, for
  // at most a minute. Any other time the page never calls Pay
  const UNRESOLVED = new Set(["new", "past_due"]);
  $effect(() => {
    if (!data.returned) return;
    let polls = 0;
    const timer = setInterval(async () => {
      const current = queryClient.getQueryData<BillingStatusDto>(
        billingKeys.status(),
      );
      if (++polls > 20 || !current || !UNRESOLVED.has(current.status)) {
        clearInterval(timer);
        return;
      }
      try {
        const fresh = await getBillingStatus({ refresh: true });
        queryClient.setQueryData(billingKeys.status(), fresh);
        if (!UNRESOLVED.has(fresh.status)) {
          clearInterval(timer);
          void queryClient.invalidateQueries({
            queryKey: billingKeys.statements(),
          });
        }
      } catch {
        // keep trying; the next tick or the notification will get it
      }
    }, 3000);
    return () => clearInterval(timer);
  });

  const onSubscribe = () =>
    subscribe.mutate(undefined, {
      onSuccess: ({ checkoutUrl }) => (location.href = checkoutUrl),
    });

  // Pay hands back a one-hour link into its own billing page for this user:
  // usage, credit, next statement, cancel or keep, and the payment method
  // through the payment provider. It links back to this page
  const onManage = () =>
    portal.mutate(undefined, {
      onSuccess: ({ portalUrl }) => (location.href = portalUrl),
    });

  const DAYS_PER_MONTH = 365.25 / 12;
  const MS_PER_MONTH = DAYS_PER_MONTH * 86_400_000;

  const formatDate = (date: Date | string | null) =>
    date ? new Date(date).toLocaleDateString() : "";
  const formatMonth = (date: Date) =>
    date.toLocaleDateString(undefined, { month: "long", year: "numeric" });
  const formatGb = (value: number) =>
    value >= 100
      ? value.toFixed(0)
      : value >= 10
        ? value.toFixed(1)
        : value.toFixed(2);
  const formatMoney = (cents: number, currency: string) =>
    new Intl.NumberFormat(undefined, {
      style: "currency",
      currency: (currency || "usd").toUpperCase(),
    }).format(cents / 100);

  /**
   * Everything the page says about money, derived in one place from what Pay
   * settled (the credit ledger, the pending charge) and what the user stores
   * right now. Only `nextStatementEstimateCents` and `monthlyCostCents` are
   * projections; both assume storage stays at today's size.
   */
  const forecast = (b: BillingStatusDto) => {
    const now = Date.now();
    const periodStart = b.currentPeriodStart
      ? new Date(b.currentPeriodStart)
      : null;
    const periodEnd = b.currentPeriodEnd ? new Date(b.currentPeriodEnd) : null;
    const periodMonths =
      periodStart && periodEnd
        ? Math.max(
            0,
            (periodEnd.getTime() - periodStart.getTime()) / MS_PER_MONTH,
          )
        : 1;
    // What the whole period will have used at today's size, less what Pay has
    // already settled for it (usage is reported as it accrues, so this is the
    // part still to come rather than the time left on the clock)
    const restOfPeriodGbMonths = Math.max(
      0,
      b.storedGb * periodMonths - b.periodGbMonths,
    );
    const beyondCredit = Math.max(
      0,
      restOfPeriodGbMonths - b.creditRemainingGbMonths,
    );
    const creditCovered = b.pendingGbMonths === 0 && beyondCredit === 0;
    const creditMonthsLeft =
      b.storedGb > 0 ? b.creditRemainingGbMonths / b.storedGb : null;
    return {
      periodEnd,
      creditCovered,
      creditExhausted: b.creditRemainingGbMonths <= 0,
      creditFraction:
        b.creditGbMonths > 0
          ? Math.min(1, b.creditUsedGbMonths / b.creditGbMonths)
          : 0,
      // How long the remaining credit lasts at today's size, and when that is
      creditMonthsLeft,
      creditRunsOut:
        creditMonthsLeft !== null && creditMonthsLeft > 0
          ? new Date(now + creditMonthsLeft * MS_PER_MONTH)
          : null,
      // The next statement: what is already pending plus the rest of the period
      nextStatementEstimateCents:
        b.pendingAmountCents + Math.round(beyondCredit * b.rateCentsPerGbMonth),
      // A full month at today's size, once no credit is left
      monthlyCostCents: Math.round(b.storedGb * b.rateCentsPerGbMonth),
      creditWorthCents: Math.round(b.creditGbMonths * b.rateCentsPerGbMonth),
    };
  };
</script>

<svelte:head><title>{$t`Billing`} &middot; FUTO Backups</title></svelte:head>

<Stack gap={6}>
  <Stack gap={2}>
    <Heading tag="h1" size="medium">{$t`Billing`}</Heading>
    <Text color="muted"
      >{$t`You pay once for a starter credit. Storage comes out of that credit first, and you are only billed for storage beyond it.`}</Text
    >
  </Stack>

  <Suspense query={status}>
    {#snippet children(billing)}
      {@const f = forecast(billing)}
      {@const money = (cents: number) => formatMoney(cents, billing.currency)}
      <div class="grid max-w-4xl gap-4 md:grid-cols-2">
        <!-- Subscription state and the actions -->
        <Card>
          <CardHeader>
            <CardTitle>{$t`Subscription`}</CardTitle>
          </CardHeader>
          <CardBody>
            <Stack gap={3}>
              {#if billing.status === "active"}
                <Alert color="success" title={$t`Subscription active`}>
                  {$t`Your backups are running.`}
                </Alert>
              {:else if billing.status === "pending_cancellation"}
                <Alert color="warning" title={$t`Pending cancellation`}>
                  {$t`Your subscription ends on ${formatDate(billing.endsAt)}. Your backups are kept and billed as usual until then. Changed your mind? Choose Keep subscription under Manage subscription.`}
                </Alert>
              {:else if billing.status === "past_due"}
                <Alert color="danger" title={$t`Payment failed`}>
                  {#if billing.subscriptionActive}
                    {$t`Your last payment did not go through. Polar retries the charge for a few days and your backups keep running meanwhile. Update your payment method under Manage subscription to be safe.`}
                  {:else}
                    {$t`Your last payment did not go through, so your backups are paused. Update your payment method under Manage subscription; they resume as soon as the charge succeeds.`}
                  {/if}
                </Alert>
              {:else if billing.status === "ended"}
                <Alert color="danger" title={$t`Subscription ended`}>
                  {$t`Your subscription has ended. Subscribe again to keep your backups running.`}
                </Alert>
              {:else}
                <Text color="secondary">
                  {$t`You don't have a subscription yet. Subscribe to keep your backups running.`}
                </Text>
              {/if}

              {#if billing.status === "new"}
                <Text size="small" color="muted">
                  {$t`The starter costs ${money(billing.starterPriceCents)} once and gives you ${formatGb(billing.creditGbMonths || billing.starterCreditCents / billing.rateCentsPerGbMonth)} GB-months of storage credit. After that, storage is ${money(billing.rateCentsPerGbMonth)} per GB-month and there is no monthly fee.`}
                </Text>
              {/if}
            </Stack>
          </CardBody>
          <CardFooter>
            <Stack direction="row" gap={2} class="flex-wrap">
              {#if billing.status === "new" || billing.status === "ended"}
                <Button
                  leadingIcon={mdiCreditCardOutline}
                  loading={subscribe.isPending}
                  onclick={onSubscribe}>{$t`Subscribe`}</Button
                >
              {/if}
              {#if billing.status !== "new"}
                <Button
                  color="secondary"
                  variant="outline"
                  leadingIcon={mdiOpenInNew}
                  loading={portal.isPending}
                  onclick={onManage}>{$t`Manage subscription`}</Button
                >
              {/if}
            </Stack>
          </CardFooter>
        </Card>

        {#if billing.status !== "new"}
          <!-- The next statement: the one number a customer wants first -->
          <Card>
            <CardHeader>
              <CardTitle>{$t`Next statement`}</CardTitle>
            </CardHeader>
            <CardBody>
              <Stack gap={2}>
                <div class="flex items-baseline gap-3">
                  <span class="text-3xl font-semibold"
                    >{f.creditCovered
                      ? money(0)
                      : `~${money(f.nextStatementEstimateCents)}`}</span
                  >
                  {#if f.periodEnd}
                    <Text color="muted"
                      >{$t`on ${formatDate(f.periodEnd)}`}</Text
                    >
                  {/if}
                </div>
                {#if billing.endsAt}
                  <Text size="small" color="muted">
                    {$t`Your subscription ends on ${formatDate(billing.endsAt)}. Any storage beyond your credit up to then is charged on the final statement.`}
                  </Text>
                {:else if f.creditCovered}
                  <Text size="small" color="muted">
                    {$t`Your storage is covered by your credit, so nothing is charged. You will see a ${money(0)} statement each month while that lasts.`}
                  </Text>
                {:else}
                  <Text size="small" color="muted">
                    {#if billing.pendingGbMonths > 0}
                      {$t`${formatGb(billing.pendingGbMonths)} GB-months beyond your credit so far this period (${money(billing.pendingAmountCents)}), plus an estimate for the rest of the period at your current ${formatGb(billing.storedGb)} GB.`}
                    {:else}
                      {$t`Your credit runs out during this period. The estimate covers the storage beyond it at your current ${formatGb(billing.storedGb)} GB.`}
                    {/if}
                  </Text>
                {/if}
                {#if !billing.endsAt}
                  <Text size="small">
                    {#if f.creditExhausted}
                      {$t`Going forward: about ${money(f.monthlyCostCents)} per month at ${formatGb(billing.storedGb)} GB.`}
                    {:else}
                      {$t`Once your credit is used up: about ${money(f.monthlyCostCents)} per month at ${formatGb(billing.storedGb)} GB.`}
                    {/if}
                  </Text>
                {/if}
              </Stack>
            </CardBody>
          </Card>

          <!-- The credit: how much is left and how long it lasts; once it is
               spent, what this period is using, day by day -->
          <Card class="md:col-span-2">
            <CardHeader>
              <CardTitle
                >{f.creditExhausted
                  ? $t`Storage this period`
                  : $t`Storage credit`}</CardTitle
              >
            </CardHeader>
            <CardBody>
              <Stack gap={3}>
                {#if f.creditExhausted}
                  {@const peak = Math.max(
                    0,
                    ...billing.periodUsage.map((d) => d.gbMonths),
                  )}
                  <div>
                    <div class="mb-1 flex justify-between text-sm">
                      <span
                        >{billing.currentPeriodStart
                          ? $t`${formatGb(billing.periodGbMonths)} GB-months since ${formatDate(billing.currentPeriodStart)}`
                          : $t`${formatGb(billing.periodGbMonths)} GB-months this period`}</span
                      >
                    </div>
                    {#if billing.periodUsage.length}
                      <div
                        class="flex h-14 items-end gap-0.5"
                        role="img"
                        aria-label={$t`Storage used per day this period`}
                      >
                        {#each billing.periodUsage as day (day.date)}
                          <div
                            class="min-w-0.5 flex-1 rounded-t-sm bg-primary"
                            style="height: {peak > 0
                              ? Math.max(
                                  2,
                                  Math.round((day.gbMonths / peak) * 100),
                                )
                              : 2}%"
                            title="{day.date}: {formatGb(
                              day.gbMonths,
                            )} GB-months"
                          ></div>
                        {/each}
                      </div>
                      <div
                        class="mt-0.5 flex justify-between text-xs text-gray-500"
                      >
                        <span>{formatDate(billing.periodUsage[0].date)}</span>
                        <span
                          >{$t`${formatGb(peak)} GB-months on the busiest day`}</span
                        >
                        <span
                          >{formatDate(
                            billing.periodUsage[billing.periodUsage.length - 1]
                              .date,
                          )}</span
                        >
                      </div>
                    {:else}
                      <Text size="small" color="muted"
                        >{$t`No storage reported yet this period.`}</Text
                      >
                    {/if}
                  </div>
                {:else}
                  <div>
                    <div class="mb-1 flex justify-between text-sm">
                      <span
                        >{$t`${formatGb(billing.creditUsedGbMonths)} of ${formatGb(billing.creditGbMonths)} GB-months used`}</span
                      >
                      <span
                        >{$t`${formatGb(billing.creditRemainingGbMonths)} GB-months left`}</span
                      >
                    </div>
                    <div
                      class="h-3 w-full overflow-hidden rounded-full bg-gray-200 dark:bg-gray-700"
                      role="progressbar"
                      aria-valuemin={0}
                      aria-valuemax={100}
                      aria-valuenow={Math.round(f.creditFraction * 100)}
                    >
                      <div
                        class="h-full rounded-full bg-primary"
                        style="width: {Math.max(1, f.creditFraction * 100)}%"
                      ></div>
                    </div>
                  </div>
                {/if}

                <Text size="small">
                  {#if billing.storedGb <= 0}
                    {$t`You are not storing anything yet. Your credit is untouched until your first backup.`}
                  {:else if f.creditExhausted}
                    {$t`You store ${formatGb(billing.storedGb)} GB, which uses ${formatGb(billing.storedGb)} GB-months every month. Your credit is used up, so storage is now billed monthly.`}
                  {:else if f.creditRunsOut}
                    {$t`You store ${formatGb(billing.storedGb)} GB, which uses ${formatGb(billing.storedGb)} GB-months every month. At that size your credit lasts about ${f.creditMonthsLeft !== null && f.creditMonthsLeft >= 1 ? `${f.creditMonthsLeft.toFixed(1)} more months` : `${Math.max(1, Math.round((f.creditMonthsLeft ?? 0) * DAYS_PER_MONTH))} more days`}, until around ${formatMonth(f.creditRunsOut)}.`}
                  {/if}
                </Text>
                {#if billing.forwardedGbMonths > 0}
                  <Text size="small" color="muted">
                    {$t`Storage beyond the credit so far: ${formatGb(billing.forwardedGbMonths)} GB-months, charged on your monthly statements.`}
                  </Text>
                {/if}

                <details class="text-sm">
                  <summary class="cursor-pointer text-muted"
                    >{$t`How billing works`}</summary
                  >
                  <ol class="mt-2 list-decimal space-y-1 ps-5">
                    <li>
                      {$t`You paid ${money(billing.starterPriceCents)} once for the starter. That bought ${formatGb(billing.creditGbMonths)} GB-months of storage credit (worth ${money(f.creditWorthCents)} at ${money(billing.rateCentsPerGbMonth)} per GB-month).`}
                    </li>
                    <li>
                      {$t`A GB-month is one gigabyte stored for one month: 10 GB kept for a month uses 10 GB-months, so does 5 GB kept for two months.`}
                    </li>
                    <li>
                      {$t`Each month, what you stored comes out of the credit first. While any credit is left you are not charged, and your monthly statement reads ${money(0)}.`}
                    </li>
                    <li>
                      {$t`Once the credit is used up, each monthly statement charges ${money(billing.rateCentsPerGbMonth)} for every GB-month beyond it. There is no other monthly fee, and you can cancel at any time under Manage subscription.`}
                    </li>
                  </ol>
                </details>
              </Stack>
            </CardBody>
          </Card>
        {/if}
      </div>
    {/snippet}
  </Suspense>

  <Suspense query={statements}>
    {#snippet children({ statements: rows })}
      {#if rows.length > 0}
        <Stack gap={2}>
          <Heading tag="h2" size="tiny" class="px-1">{$t`Statements`}</Heading>
          <table class="w-full max-w-4xl text-left text-sm">
            <thead>
              <tr>
                <th class="px-1 py-1">{$t`Date`}</th>
                <th class="px-1 py-1">{$t`Storage that month`}</th>
                <th class="px-1 py-1">{$t`Charged`}</th>
              </tr>
            </thead>
            <tbody>
              {#each rows as statement (statement.orderId)}
                <tr>
                  <td class="px-1 py-1">{formatDate(statement.createdAt)}</td>
                  <td class="px-1 py-1"
                    >{formatGb(statement.gigabyteMonthsUsed)} GB-months</td
                  >
                  <td class="px-1 py-1"
                    >{formatMoney(statement.amountCents, statement.currency)}
                    {#if statement.billingReason === "subscription_create"}
                      <span class="text-muted">({$t`starter`})</span>
                    {/if}</td
                  >
                </tr>
              {/each}
            </tbody>
          </table>
        </Stack>
      {/if}
    {/snippet}
  </Suspense>
</Stack>
