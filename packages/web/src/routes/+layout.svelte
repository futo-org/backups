<script lang="ts">
  import "./layout.css";
  import favicon from "$lib/assets/favicon.svg";

  import {
    setYuccaLanguage,
    YuccaContext,
  } from "@futo-org/backups-orchestrator-ui";

  void setYuccaLanguage("en");

  const { children } = $props();
</script>

<svelte:head>
  <title>FUTO Backups</title>
  <link rel="icon" href={favicon} />
</svelte:head>
<YuccaContext>
  {@render children()}
</YuccaContext>
