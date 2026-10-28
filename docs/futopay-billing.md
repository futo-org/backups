# FUTO Pay billing

Billing is delegated to FUTO Pay (`lib-polar`). Pay owns the Polar checkout, the
subscription, the starter credit and the per-gigabyte-month metering; yucca only
asks Pay where a customer stands, sends users to Pay's checkout, reports storage
usage and keeps a cache of what Pay last said. Nothing here is enabled unless
`FUTOPAY_URL` is set.

## Identity

Pay identifies a customer by `external_customer_id`, which is the user's OIDC
`sub`, with the account email as the fallback. Both are sent on every call.

## yucca-api

| Route                               | Auth                        | What it does                                                                                       |
| ----------------------------------- | --------------------------- | -------------------------------------------------------------------------------------------------- |
| `GET /api/billing?refresh=`         | session                     | Cached `BillingStatusDto`; `refresh=true` re-reads Pay first                                       |
| `GET /api/billing/statements`       | session                     | Statements Pay reported through `usage.paid`                                                       |
| `POST /api/billing/subscribe`       | session                     | Asks Pay for a checkout URL (`return_url` = `<Origin>/dashboard/billing`); 400 when already active |
| `POST /api/billing/portal`          | session                     | Asks Pay for a Polar customer-portal URL (same `return_url`); 400 when there is no subscription   |
| `POST /api/billing/futopay/webhook` | Standard Webhooks signature | Receives `customer.state` and `usage.paid`; 200 `{status: received \| duplicate}`                  |
| `GET /api/internal/billing/webhook-deliveries?limit=` | `x-internal-secret` | The deliveries accepted above, newest first (`{deliveries: [{id, event, receivedAt}]}`); Pay's side is `GET customers/../notifications` |

The **Manage subscription** button on `/dashboard/billing` goes through
`POST /api/billing/portal`: Pay creates a short-lived Polar customer session
and the browser is sent to Polar's portal, where the customer updates their
card, cancels or keeps the subscription and sees invoices. It is offered to
any user with a subscription, active or not, since a past-due customer fixes
the failed card there. What they change arrives back as `customer.state`.

The Billing page never makes yucca call Pay on an ordinary view: `GET
/api/billing` answers from `users.billingState`, which Pay's `customer.state`
notifications keep current, and `storedGb` comes from yucca's own repository
meters. Pay is read with `refresh=true` only when the customer has just paid
or may have: on the return from Polar's checkout (`?checkout_id=`, which Pay
has Polar fill into the return URL) and on the return from Pay's billing page
(`?billing=refresh`, which Pay appends to the back link). In those two cases
the page also keeps asking every 3 s for up to a minute while the status is
still `new` or `past_due`, then stops. Pay, for its part, re-reads the
subscription from Polar the moment the browser comes back from Polar's page
and notifies yucca of any change, so the push and the pull meet in the middle.
A cached state that predates the pricing fields is refreshed once as well.

`BillingStatusDto` carries, besides the state and the credit ledger, the
price list (`starterPriceCents`, `starterCreditCents`, `rateCentsPerGbMonth`,
`currency`), the charge already pending for the next statement
(`pendingGbMonths` / `pendingAmountCents`: usage beyond the credit that no
statement has covered yet) and `storedGb`, the user's billable storage right
now from the repository meters. The Billing page projects from those: how many
months the credit lasts at the current size, what the next statement will be,
and the monthly cost once the credit is gone. Nothing on the page is a number
Pay has not already settled except the two estimates, which say so.

`BillingStatusDto.status` is finer than Pay's three states, derived from the
cached state's `reason` and `ends_at`: `new`; `active`; `pending_cancellation`
(active with `endsAt`: backups run and billing is unchanged until then);
`past_due` (a failed renewal charge while Polar retries; `subscriptionActive`
says whether backups run meanwhile, per Pay's `CLOUD__PAST_DUE_IS_INACTIVE`);
`ended` (cancelled and past its date, retries exhausted, or never completed).
`users.billingStatus` keeps Pay's `active` / `inactive`, which is what gates
backups. The page re-reads the cached status every 15 seconds while open.

**Manage subscription** goes to Pay's own billing page for the user
(`POST /api/billing/portal` → a one-hour tokened URL on Pay), which shows the
same usage, credit and next statement, lets them cancel at period end or keep
the subscription, and links back here. Only updating the card leaves Pay, for
Polar's hosted payment page.

Only `customer.state` changes a user's billing state. `usage.paid` carries a state snapshot too, but Pay delivers notifications in creation order, and a retried charge reactivates and pays at once, so the snapshot in `usage.paid` can be the older of the two; it only upserts the statement.

Pay's calls, all under `{FUTOPAY_URL}/api/v1/cloud/{FUTOPAY_ORG_SLUG}/` with
`Authorization: Bearer {FUTOPAY_API_KEY}`:

- `GET customers/status?external_customer_id=&email=`
- `POST customers/signup` `{email, external_customer_id, return_url}`
- `POST customers/portal` `{email, external_customer_id, return_url}` → `{portal_url, state, subscription_id}`: a one-hour link into Pay's billing page for the customer; 404 for a customer Pay has never seen
- `POST usage` `{reports: [{usage_id, external_customer_id, email, megabyte_months, period_start, period_end}]}`
- `GET notifications?subscription_id=&limit=` and `POST notifications/{id}/resend`: Pay's log of what it sent to the webhook above and a way to send one again under the same `webhook-id` (yucca answers `duplicate`)

Webhook deliveries are deduplicated on the `webhook-id` header
(`billingWebhookDeliveries`); a redelivery answers `duplicate` and changes
nothing. `users.billingStatus` / `billingState` hold Pay's last answer;
`billingStatements` is keyed on Pay's `polar_order_id`.

## yucca-metrics-worker

`UsageReportService` turns `repositoryMeterHistory` into megabyte-months per
user and period, and posts them to Pay. Every 15 minutes it closes each elapsed
period (`FUTOPAY_USAGE_PERIOD`: `hour`, `day` or `month`, UTC-aligned, the last
`FUTOPAY_USAGE_LOOKBACK_PERIODS` of them, about six weeks by default, so a worker
outage shorter than that is caught up without a backfill) that has no
`usageReports` row for the user yet, then sends every pending row in batches of 500.

The integral per repository is a step function over `[periodStart, periodEnd)`:
the last sample before the period carries in, each later sample holds until the
next, and a repository with no sample before or during the period counts as
zero. Each sample is floored with `billableBytes(connection.type, sizeBytes,
objectCount)` before integration, then

    megabyteMonths = Σ bytes·seconds / (MiB × (365.25 / 12) days)

`usage_id` is `{userId}:{periodStart ISO}`; Pay treats a repeat as a duplicate,
so a row that was sent but not acknowledged is safe to resend. A result of
`not_billable` (no active subscription at Pay) is final for that period.

Internal endpoints, guarded by `x-internal-secret: {INTERNAL_SECRET}`:

- `POST /internal/metrics/sync` runs the RadosGW sync now.
- `POST /internal/usage/close-period` `{periodStart, periodEnd}` closes that
  exact period for every user, sends pending rows and returns `{created,
results, reports}`.

Deleting a repository cascade-deletes its meter history, so usage from a period
closed after the deletion is lost for that repository.

## Environment

| Variable                                                                                  | yucca-api | metrics-worker |
| ----------------------------------------------------------------------------------------- | --------- | -------------- |
| `FUTOPAY_URL`                                                                             | ✓         | ✓              |
| `FUTOPAY_ORG_SLUG`                                                                        | ✓         | ✓              |
| `FUTOPAY_API_KEY` (Pay key with `cloud:read` + `cloud:write`)                             | ✓         | ✓              |
| `FUTOPAY_WEBHOOK_SECRET` (`whsec_…`, shared with Pay's `CLOUD__WEBHOOK_SECRET`)           | ✓         |                |
| `FUTOPAY_USAGE_PERIOD` (`day`)                                                            |           | ✓              |
| `FUTOPAY_USAGE_LOOKBACK_PERIODS` (about six weeks: `1080` hours, `45` days or `3` months) |           | ✓              |
| `INTERNAL_SECRET`                                                                         | ✓         | ✓              |

`packages/mock-rgw-admin` stands in for RadosGW's admin API in compose
(`mise dev` has no RGW): `PUT /_mock/buckets/{repositoryId} {bytes, objects}`
sets what `GET /admin/bucket?format=json&stats=true` reports. Point the
topology's `rgw_admin_endpoint` at it and give the worker any `RADOS_*` values.

## Not done here

- Suspending backups while `billingStatus` is `inactive`.
- Helm and Terraform wiring of the `FUTOPAY_*` secrets (the `POLAR_*`
  placeholders in `charts/apps/yucca-metrics-worker/values.yaml` are what they
  replace).
- `.env.example` entries.
