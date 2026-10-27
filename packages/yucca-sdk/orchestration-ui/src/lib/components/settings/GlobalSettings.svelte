<script lang="ts">
  import { Container } from "@immich/ui";
  import SettingsBackends from "./SettingsBackends.svelte";
  import SettingsSupportMode from "./SettingsSupportMode.svelte";
</script>

<Container size="large" center>
  <SettingsBackends />
  <SettingsSupportMode />
</Container>
