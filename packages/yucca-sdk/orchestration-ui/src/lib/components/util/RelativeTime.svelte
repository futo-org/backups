<script lang="ts">
  import { DateTime } from "luxon";
  import { onDestroy, onMount } from "svelte";
  import { gt } from "svelte-i18n-lingui";

  type Props = {
    time: string;
    absolute?: boolean;
  };

  const props: Props = $props();

  const format = () => {
    const time = DateTime.fromISO(props.time);
    return DateTime.now().diff(time).as('minute') < 1 ? gt`a moment ago` : time.toRelative();
  };

  let text = $state(format());

  const timestamp = $derived(
    DateTime.fromISO(props.time).toLocaleString(DateTime.DATETIME_MED),
  );

  let interval: ReturnType<typeof setInterval>;

  onMount(() => (interval = setInterval(() => (text = format()), 1000)));
  onDestroy(() => clearInterval(interval));
</script>

<time datetime={props.time} title={props.absolute ? text : timestamp}
  >{props.absolute ? timestamp : text}</time
>
