import type { PageLoad } from './$types';
import { getBillingStatus } from '@futo-org/backups-api-client';

export const load: PageLoad = async ({ fetch, url }) => {
  // Returning from Polar's checkout (checkout_id, which Pay has Polar fill in)
  // or from Pay's billing page (billing=refresh): something may just have been
  // paid, so ask Pay once instead of serving the cache, and let the page keep
  // asking for a short while if the answer is still unresolved
  const returned =
    url.searchParams.has('checkout_id') ||
    url.searchParams.get('billing') === 'refresh';
  return {
    returned,
    initialData: await getBillingStatus({ refresh: returned }, { fetch }),
  };
};
