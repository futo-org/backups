import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { z } from 'zod';
import { env } from './env.js';

const messageSchema = z.object({
  from: z.string(),
  to: z.union([z.string(), z.array(z.string()).min(1)]),
  subject: z.string(),
  html: z.string().optional(),
  text: z.string().optional(),
  tags: z.array(z.object({ name: z.string(), value: z.string() })).optional(),
});

type ResendMessage = z.infer<typeof messageSchema>;

const parseAddress = (address: string) => {
  const match = address.match(/^\s*(.*?)\s*<([^>]+)>\s*$/);
  return match ? { Name: match[1], Email: match[2] } : { Name: '', Email: address.trim() };
};

const deliverToMailpit = async (message: ResendMessage) => {
  const recipients = Array.isArray(message.to) ? message.to : [message.to];
  const response = await fetch(new URL('/api/v1/send', env.MAILPIT_URL), {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      From: parseAddress(message.from),
      To: recipients.map((address) => parseAddress(address)),
      Subject: message.subject,
      HTML: message.html ?? '',
      Text: message.text ?? '',
      Tags: (message.tags ?? []).map((tag) => tag.value),
    }),
  });
  if (!response.ok) {
    throw new Error(`Mailpit send failed: ${response.status} ${response.statusText} — ${await response.text()}`);
  }
  const { ID } = (await response.json()) as { ID: string };
  return { id: ID };
};

// Resend's error body: { statusCode, name, message }.
const errorBody = (statusCode: number, name: string, message: string) => ({ statusCode, name, message });

const readBody = (request: IncomingMessage): Promise<string> =>
  new Promise((resolve, reject) => {
    let data = '';
    request.on('data', (chunk) => (data += chunk));
    request.on('end', () => resolve(data));
    request.on('error', reject);
  });

const respond = (response: ServerResponse, status: number, body: unknown) => {
  response.writeHead(status, { 'Content-Type': 'application/json' });
  response.end(JSON.stringify(body));
};

const server = createServer((request, response) => {
  handle(request, response).catch((error: unknown) => {
    console.error(error);
    respond(response, 500, errorBody(500, 'internal_server_error', `${error}`));
  });
});

async function handle(request: IncomingMessage, response: ServerResponse): Promise<void> {
  const path = new URL(request.url ?? '/', 'http://localhost').pathname;

  if (request.method === 'GET' && path === '/health') {
    respond(response, 200, { status: 'ok' });
    return;
  }

  if (request.method !== 'POST' || (path !== '/emails' && path !== '/emails/batch')) {
    respond(response, 404, errorBody(404, 'not_found', `No such endpoint: ${request.method} ${path}`));
    return;
  }

  if (!request.headers.authorization?.startsWith('Bearer ')) {
    respond(response, 401, errorBody(401, 'missing_api_key', 'Missing API key in the authorization header.'));
    return;
  }

  const body: unknown = JSON.parse(await readBody(request));

  // Like Resend, a batch is validated as a whole: one bad email rejects all of them.
  const parsed = path === '/emails' ? messageSchema.safeParse(body) : z.array(messageSchema).max(100).safeParse(body);
  if (!parsed.success) {
    respond(response, 422, errorBody(422, 'validation_error', parsed.error.message));
    return;
  }

  if (!Array.isArray(parsed.data)) {
    respond(response, 200, await deliverToMailpit(parsed.data));
    return;
  }
  const data = [];
  for (const message of parsed.data) {
    data.push(await deliverToMailpit(message));
  }
  respond(response, 200, { data });
}

server.listen(env.PORT, () => {
  console.log(`mock-resend-provider listening on :${env.PORT}, delivering to ${env.MAILPIT_URL}`);
});
