import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { z } from 'zod';
import { env } from './env.js';

const bucketStatsSchema = z.object({
  bytes: z.number().int().nonnegative(),
  objects: z.number().int().nonnegative(),
});

type BucketStats = z.infer<typeof bucketStatsSchema>;

const buckets = new Map<string, BucketStats>();

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

const adminBucketListing = () =>
  [...buckets.entries()].map(([bucket, stats]) => ({
    bucket,
    id: `mock.${bucket}`,
    owner: 'mock',
    usage: { 'rgw.main': { size: stats.bytes, size_actual: stats.bytes, num_objects: stats.objects } },
  }));

const server = createServer((request: IncomingMessage, response: ServerResponse) => {
  handle(request, response).catch((error) => {
    console.error(error);
    respond(response, 500, { Code: 'InternalError', Message: `${error}` });
  });
});

async function handle(request: IncomingMessage, response: ServerResponse): Promise<void> {
  const url = new URL(request.url ?? '/', 'http://localhost');
  const path = url.pathname;

  if (request.method === 'GET' && path === '/health') {
    respond(response, 200, { status: 'ok' });
    return;
  }

  if (request.method === 'GET' && path === '/admin/bucket') {
    const bucket = url.searchParams.get('bucket');
    if (bucket) {
      const stats = buckets.get(bucket);
      if (!stats) {
        respond(response, 404, { Code: 'NoSuchBucket' });
        return;
      }
      respond(
        response,
        200,
        adminBucketListing().find((entry) => entry.bucket === bucket),
      );
      return;
    }
    respond(response, 200, url.searchParams.get('stats') === 'true' ? adminBucketListing() : [...buckets.keys()]);
    return;
  }

  if (request.method === 'GET' && path === '/_mock/buckets') {
    respond(response, 200, Object.fromEntries(buckets));
    return;
  }

  const match = path.match(/^\/_mock\/buckets\/([^/]+)$/);
  if (match) {
    const bucket = decodeURIComponent(match[1]);
    if (request.method === 'PUT') {
      const parsed = bucketStatsSchema.safeParse(JSON.parse((await readBody(request)) || '{}'));
      if (!parsed.success) {
        respond(response, 422, { Code: 'InvalidArgument', Message: parsed.error.message });
        return;
      }
      buckets.set(bucket, parsed.data);
      respond(response, 200, { bucket, ...parsed.data });
      return;
    }
    if (request.method === 'DELETE') {
      buckets.delete(bucket);
      respond(response, 204, null);
      return;
    }
  }

  respond(response, 404, { Code: 'NoSuchKey', Message: `No such endpoint: ${request.method} ${path}` });
}

server.listen(env.PORT, () => {
  console.log(`mock-rgw-admin listening on :${env.PORT}`);
});
