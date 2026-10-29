<script>
  import { TooltipProvider } from "@immich/ui";
  import { configureYucca } from "$lib/providers";

  const { children } = $props();

  configureYucca({ api: "orchestrator", language: "en" });
</script>

<TooltipProvider>
  {@render children()}
</TooltipProvider>
