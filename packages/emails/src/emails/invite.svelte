<script lang="ts">
  import { Button, Link, Section, Text } from '@better-svelte-email/components';
  import Layout from '../lib/layout.svelte';

  let { inviteCode, inviteUrl }: { inviteCode: string; inviteUrl: string } = $props();
</script>

<Layout preview="You're invited to the FUTO Backups beta">
  <Text>Hello,</Text>
  <Text>
    You previously consented to receive emails when we were ready to invite you to the FUTO Backups private beta. Well,
    the time is now. You're officially invited to come test out FUTO Backups with us for the next few weeks, and it's
    free!
  </Text>
  <Text>
    During the beta, all support requests must go to Immich's Discord
    <Link href="https://discord.immich.app/">https://discord.immich.app/</Link> in the FUTO Backups
    <Link href="https://discord.com/channels/979116623879368755/1544327852433088562">#backups-general</Link>,
    <Link href="https://discord.com/channels/979116623879368755/1544327851359084654">#backups-customer</Link> or
    <Link href="https://discord.com/channels/979116623879368755/1544327850297921586">#backups-support</Link> channels. For
    setup instructions and documentation, please see
    <Link href="https://docs.futo.cloud/">https://docs.futo.cloud/</Link>. It's important to note that the beta requires
    you to run a non-tagged version of Immich, but we keep it up to date with the latest releases. We aim to get this
    merged and tagged as soon as possible.
  </Text>
  <Text>
    To set up Immich, follow these instructions
    <Link href="https://docs.futo.cloud/getting-started/immich">https://docs.futo.cloud/getting-started/immich</Link>.
  </Text>
  <Text>
    The data you back up is encrypted end-to-end with a key only you control, we can never access, see, or decrypt your
    data. While in the beta, we make no guarantee relating to data durability, integrity or service availability. We may
    at any moment wipe all data contained in our storage cluster.
  </Text>
  <Text>
    The source code for FUTO Backups is available at
    <Link href="https://github.com/futo-org/backups">https://github.com/futo-org/backups</Link>.
  </Text>
  <Text>
    We're excited to have you join and test this out with us,<br />
    - The FUTO Backups team
  </Text>
  <Text>Use this invite code to sign up:</Text>
  <Section class="my-6 rounded-xl bg-neutral-100 px-4 py-5 text-center font-mono text-2xl tracking-widest text-dark">
    {inviteCode}
  </Section>
  <Section class="my-8 text-center">
    <Button href={inviteUrl} class="rounded-lg bg-primary px-6 py-3 text-base font-medium text-white">
      Join the beta
    </Button>
  </Section>
  <Text class="text-sm text-subtle">
    If the button doesn't work, open <Link href={inviteUrl}>{inviteUrl}</Link> and enter the code above.
  </Text>
</Layout>
