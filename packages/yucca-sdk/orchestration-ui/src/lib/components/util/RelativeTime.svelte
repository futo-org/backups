<script lang="ts">
  import { now } from "$lib/utils/now";
  import { DateTime } from "luxon";
  import { gt } from "svelte-i18n-lingui";

  type Props = {
    time: string;
    absolute?: boolean;
  };

  const props: Props = $props();

  const text = $derived.by(() => {
    const time = DateTime.fromISO(props.time);
    const base = DateTime.fromMillis($now);
    return base.diff(time).as('minute') < 1 ? gt`a moment ago` : time.toRelative({ base });
  });

  const timestamp = $derived(
    DateTime.fromISO(props.time).toLocaleString(DateTime.DATETIME_MED),
  );
</script>

<time datetime={props.time} title={props.absolute ? text : timestamp}
  >{props.absolute ? timestamp : text}</time
>
