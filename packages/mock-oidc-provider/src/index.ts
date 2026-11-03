import { createServer } from 'node:http';
import Provider, { type Configuration } from 'oidc-provider';
import { env } from './env.js';

type ProviderCtx = Parameters<Parameters<Provider['use']>[0]>[0];

// The email each account signed in with. The login page asks for it, so a
// person gets to use an address that is really theirs (a real Polar refuses a
// made-up one at a reserved domain such as `.test`, and emails the receipts
// to it); the /api/form back channel takes it as `email=` for the same
// reason. An account that never gave one keeps the fixture address, which is
// all the integration suites and the mock Polar need.
const emails = new Map<string, string>();
const FIXTURE_EMAIL_DOMAIN = 'example.test';
const EMAIL_SHAPE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function emailFor(sub: string): string {
  return emails.get(sub) ?? `${sub}@${FIXTURE_EMAIL_DOMAIN}`;
}

function rememberEmail(sub: string, email: unknown): string | undefined {
  if (typeof email !== 'string') {
    return undefined;
  }
  const trimmed = email.trim();
  if (!EMAIL_SHAPE.test(trimmed)) {
    return `"${trimmed}" is not an email address`;
  }
  emails.set(sub, trimmed);
  return undefined;
}

const configuration: Configuration = {
  clients: [
    {
      client_id: env.CLIENT_ID,
      client_secret: env.CLIENT_SECRET,
      redirect_uris: [env.REDIRECT_URI, env.TICKET_REDIRECT_URI, env.ADMIN_REDIRECT_URI],
      require_auth_time: true,
      post_logout_redirect_uris: [env.POST_LOGOUT_REDIRECT_URI, env.ADMIN_POST_LOGOUT_REDIRECT_URI],
      grant_types: ['authorization_code'],
      response_types: ['code'],
      token_endpoint_auth_method: 'client_secret_basic',
    },
    {
      client_id: env.DEVICE_CLIENT_ID,
      redirect_uris: [],
      grant_types: ['urn:ietf:params:oauth:grant-type:device_code'],
      response_types: [],
      token_endpoint_auth_method: 'none',
    },
  ],
  features: {
    // Replaced by the login page below, which asks for an email as well
    devInteractions: { enabled: false },
    deviceFlow: { enabled: true },
    rpInitiatedLogout: { enabled: true },
    resourceIndicators: { enabled: false },
  },
  interactions: {
    url: (_ctx, interaction) => `/interaction/${interaction.uid}`,
  },
  // Every client here is first party: grant whatever was asked without a
  // consent page, as the dev interactions used to
  loadExistingGrant: async (ctx) => {
    const client = ctx.oidc.client;
    const session = ctx.oidc.session;
    if (!client || !session?.accountId) {
      return undefined;
    }
    const grantId = ctx.oidc.result?.consent?.grantId ?? session.grantIdFor(client.clientId);
    if (grantId) {
      const existing = await ctx.oidc.provider.Grant.find(grantId);
      if (existing) {
        return existing;
      }
    }
    const grant = new ctx.oidc.provider.Grant({ clientId: client.clientId, accountId: session.accountId });
    grant.addOIDCScope(typeof ctx.oidc.params?.scope === 'string' ? ctx.oidc.params.scope : 'openid');
    grant.addOIDCClaims(['sub', 'name', 'email', 'email_verified']);
    await grant.save();
    return grant;
  },
  conformIdTokenClaims: false,
  pkce: { required: () => true },
  scopes: ['openid', 'profile', 'email'],
  claims: {
    acr: null,
    sid: null,
    auth_time: null,
    iss: null,
    openid: ['sub'],
    profile: ['name'],
    email: ['email', 'email_verified'],
  },
  cookies: { keys: ['mock-oidc-provider-dev'] },
  ttl: {
    AccessToken: 3600,
    AuthorizationCode: 600,
    DeviceCode: 600,
    IdToken: 3600,
    RefreshToken: 86_400,
  },
  findAccount: (_ctx, sub) => ({
    accountId: sub,
    claims: () => ({ sub, name: sub, email: emailFor(sub), email_verified: true }),
  }),
};

function loginPage(uid: string, values: { sub?: string; email?: string }, error?: string): string {
  const esc = (v: string | undefined): string =>
    (v ?? '').replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('"', '&quot;');
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Sign in (mock)</title>
<style>
  body { font: 16px system-ui, sans-serif; margin: 0; padding: 2rem; background: #f6f6f6; color: #222; }
  form { max-width: 24rem; margin: 2rem auto; padding: 1.5rem; background: #fff; border-radius: 8px; box-shadow: 0 1px 4px rgba(0,0,0,.15); }
  h1 { font-size: 1.2rem; margin: 0 0 .25rem; }
  p { margin: .25rem 0 1rem; color: #555; font-size: .9rem; }
  label { display: block; margin: .75rem 0 .25rem; font-weight: 600; }
  input { width: 100%; box-sizing: border-box; padding: .5rem; font-size: 1rem; border: 1px solid #bbb; border-radius: 4px; }
  small { display: block; margin-top: .25rem; color: #666; }
  button { margin-top: 1.25rem; width: 100%; padding: .6rem; font-size: 1rem; border: 0; border-radius: 4px; background: #2563eb; color: #fff; }
  .error { color: #b91c1c; margin: .5rem 0 0; }
</style></head>
<body><form method="post" action="/interaction/${esc(uid)}">
  <h1>Sign in</h1>
  <p>Mock identity provider: any username and password are accepted.</p>
  <label for="sub">Username</label>
  <input id="sub" name="sub" autocomplete="username" required autofocus value="${esc(values.sub)}">
  <small>Becomes the account's id (the OIDC <code>sub</code>).</small>
  <label for="email">Email</label>
  <input id="email" name="email" type="email" autocomplete="email" required value="${esc(values.email)}">
  <small>Sent as the account's verified email. Against the real Polar sandbox use an address Polar accepts; reserved domains such as <code>.test</code> are refused there.</small>
  <label for="password">Password</label>
  <input id="password" name="password" type="password" autocomplete="current-password">
  ${error ? `<p class="error">${esc(error)}</p>` : ''}
  <button type="submit">Sign in</button>
</form></body></html>`;
}

async function readForm(ctx: ProviderCtx): Promise<URLSearchParams> {
  const chunks: Buffer[] = [];
  for await (const chunk of ctx.req) {
    chunks.push(typeof chunk === 'string' ? Buffer.from(chunk) : chunk);
  }
  return new URLSearchParams(Buffer.concat(chunks).toString('utf8'));
}

async function handleInteraction(provider: Provider, ctx: ProviderCtx, uid: string): Promise<void> {
  const details = await provider.interactionDetails(ctx.req, ctx.res);
  if (details.uid !== uid) {
    ctx.status = 400;
    ctx.body = { error: 'interaction mismatch' };
    return;
  }
  if (details.prompt.name !== 'login') {
    // Consent never prompts (loadExistingGrant); anything else is unexpected
    ctx.status = 400;
    ctx.body = { error: `unsupported prompt ${details.prompt.name}` };
    return;
  }
  if (ctx.method === 'GET') {
    ctx.type = 'html';
    ctx.body = loginPage(uid, {});
    return;
  }
  const form = await readForm(ctx);
  const sub = (form.get('sub') ?? '').trim();
  const email = form.get('email') ?? '';
  const problem = sub ? rememberEmail(sub, email) : 'a username is required';
  if (problem) {
    ctx.status = 400;
    ctx.type = 'html';
    ctx.body = loginPage(uid, { sub, email }, problem);
    return;
  }
  await provider.interactionFinished(
    ctx.req,
    ctx.res,
    { login: { accountId: sub } },
    { mergeWithLastSubmission: false },
  );
  // interactionFinished wrote the redirect itself
  ctx.respond = false;
}

async function issueAuthorizationCode(provider: Provider, ctx: ProviderCtx): Promise<void> {
  const { sub, email, client_id, redirect_uri, state, code_challenge, code_challenge_method, scope } = ctx.query;

  if (typeof sub !== 'string' || typeof client_id !== 'string' || typeof redirect_uri !== 'string') {
    ctx.status = 400;
    ctx.body = { error: 'sub, client_id, and redirect_uri are required query parameters' };
    return;
  }
  // Optional: the address this headless sign-in is for, so a console driving
  // an account someone created at the login page keeps that account's email
  const problem = rememberEmail(sub, email);
  if (problem) {
    ctx.status = 400;
    ctx.body = { error: problem };
    return;
  }

  const client = await provider.Client.find(client_id);
  if (!client) {
    ctx.status = 404;
    ctx.body = { error: `client_id "${client_id}" not found` };
    return;
  }

  const grantedScope = typeof scope === 'string' ? scope : 'openid';
  const grant = new provider.Grant({ accountId: sub, clientId: client_id });
  grant.addOIDCScope(grantedScope);
  const grantId = await grant.save();

  const code = new provider.AuthorizationCode({
    accountId: sub,
    authTime: Math.floor(Date.now() / 1000),
    // /api/form skips the authorization endpoint, so assign_claims never marks
    // auth_time essential the way require_auth_time would.
    claims: { id_token: { auth_time: { essential: true } } },
    client,
    redirectUri: redirect_uri,
    scope: grantedScope,
    codeChallenge: typeof code_challenge === 'string' ? code_challenge : undefined,
    codeChallengeMethod: typeof code_challenge_method === 'string' ? code_challenge_method : undefined,
    grantId,
    gty: 'authorization_code',
  });
  const codeValue = await code.save();

  const callback = new URL(redirect_uri);
  callback.searchParams.set('code', codeValue);
  callback.searchParams.set('iss', env.ISSUER);
  if (typeof state === 'string') {
    callback.searchParams.set('state', state);
  }
  ctx.redirect(callback.href);
}

async function approveDeviceCode(provider: Provider, ctx: ProviderCtx): Promise<void> {
  const { user_code, sub } = ctx.query;

  if (typeof user_code !== 'string' || typeof sub !== 'string') {
    ctx.status = 400;
    ctx.body = { error: 'user_code and sub are required query parameters' };
    return;
  }

  const normalized = user_code.toUpperCase().replaceAll(/\W/g, '');
  const deviceCode = await provider.DeviceCode.findByUserCode(normalized);
  if (!deviceCode) {
    ctx.status = 404;
    ctx.body = { error: `user_code "${user_code}" not found` };
    return;
  }

  const requestedScope = deviceCode.params?.scope;
  const grantedScope = typeof requestedScope === 'string' ? requestedScope : 'openid';

  const grant = new provider.Grant({ accountId: sub, clientId: deviceCode.clientId });
  grant.addOIDCScope(grantedScope);
  const grantId = await grant.save();

  deviceCode.accountId = sub;
  deviceCode.grantId = grantId;
  deviceCode.scope = grantedScope;
  deviceCode.authTime = Math.floor(Date.now() / 1000);
  await deviceCode.save();

  ctx.body = { ok: true };
}

function bootstrap(): void {
  const provider = new Provider(env.ISSUER, configuration);

  provider.use(async (ctx, next) => {
    const interaction = /^\/interaction\/([^/]+)$/.exec(ctx.path);
    if (interaction && (ctx.method === 'GET' || ctx.method === 'POST')) {
      await handleInteraction(provider, ctx, interaction[1]);
      return;
    }
    if (ctx.method === 'GET') {
      switch (ctx.path) {
        case '/api/form': {
          await issueAuthorizationCode(provider, ctx);
          return;
        }
        case '/api/form/device': {
          await approveDeviceCode(provider, ctx);
          return;
        }
        case '/session/end': {
          const postLogoutUri = ctx.query.post_logout_redirect_uri;
          if (typeof postLogoutUri === 'string') {
            ctx.status = 302;
            ctx.set('Location', postLogoutUri);
            return;
          }
          break;
        }
      }
    }
    await next();
  });

  const handler = provider.callback();
  createServer((req, res) => {
    void handler(req, res);
  }).listen(env.PORT, () => {
    console.log(`mock-oidc-provider listening on port ${env.PORT} (issuer: ${env.ISSUER})`);
  });
}

bootstrap();
