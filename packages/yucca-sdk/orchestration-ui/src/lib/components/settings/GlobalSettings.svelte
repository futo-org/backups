<script lang="ts">
  import { Container } from "@immich/ui";
  import SettingsBackends from "./SettingsBackends.svelte";
  import SettingsBandwidth from "./SettingsBandwidth.svelte";
  import SettingsSupportMode from "./SettingsSupportMode.svelte";
</script>

<Container size="large" center>
  <SettingsBackends />
  <SettingsBandwidth />
  <SettingsSupportMode />
</Container>
