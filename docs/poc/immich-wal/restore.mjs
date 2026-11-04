import { spawn, spawnSync } from 'node:child_process';
import { createWriteStream } from 'node:fs';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { parseArgs } from 'node:util';

const dist = resolve(import.meta.dirname, '../../../packages/yucca-sdk/orchestration-api/dist');
const { getTagValue, planWalRestore } = await import(join(dist, 'utils/wal.js'));
const { ResticTagPrefix } = await import(join(dist, 'enum.js'));

const DEFAULT_IMAGE =
  'ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0@sha256:bcf63357191b76a916ae5eb93464d65c07511da41e3bf7a8416db519b40b1c23';
const SCRATCH_WAL = '/var/lib/postgresql/restore-wal';
const PROMOTE_TIMEOUT_MS = 10 * 60 * 1000;

const usage = `usage: restore.mjs (--snapshot <id> | --lsn <lsn> | --time <iso> | --latest) (--load-cmd <cmd> | --dump-to <file>)
  RESTIC_REPOSITORY and RESTIC_PASSWORD select the repository; restic and docker must be on PATH.
  --image <image>     Postgres image matching the source (default: Immich's pinned image)
  --db-user <user>    database user in the scratch instance (default: postgres)
  --db-name <name>    database to dump from the scratch instance (default: immich)
  --keep              keep the scratch container and work directory for inspection`;

const { values: options } = parseArgs({
  options: {
    snapshot: { type: 'string' },
    lsn: { type: 'string' },
    time: { type: 'string' },
    latest: { type: 'boolean', default: false },
    'load-cmd': { type: 'string' },
    'dump-to': { type: 'string' },
    image: { type: 'string', default: DEFAULT_IMAGE },
    'db-user': { type: 'string', default: 'postgres' },
    'db-name': { type: 'string', default: 'immich' },
    keep: { type: 'boolean', default: false },
  },
});

const log = (message) => process.stderr.write(`[restore] ${message}\n`);

const run = (command, args, { allowFailure = false } = {}) => {
  const result = spawnSync(command, args, { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 });
  if (result.status !== 0 && !allowFailure) {
    throw new Error(`${command} ${args.join(' ')} failed: ${result.stderr || result.error}`);
  }
  return result;
};

const restic = (...args) => run('restic', args).stdout;

const listSnapshots = (...args) =>
  JSON.parse(restic('snapshots', '--json', '--no-lock', ...args)).map((snapshot) => ({
    ...snapshot,
    time: new Date(snapshot.time),
    summary: snapshot.summary ? { ...snapshot.summary, backup_end: new Date(snapshot.summary.backup_end) } : undefined,
  }));

const resolveTarget = () => {
  if (options.snapshot) {
    const [snapshot] = listSnapshots(options.snapshot);
    const lsn = getTagValue(snapshot?.tags, ResticTagPrefix.ImmichWalLsn);
    if (!lsn) {
      throw new Error(`Snapshot ${options.snapshot} has no ${ResticTagPrefix.ImmichWalLsn} tag`);
    }
    return { lsn };
  }
  if (options.lsn) {
    return { lsn: options.lsn };
  }
  if (options.time) {
    return { time: new Date(options.time) };
  }
  if (options.latest) {
    return 'latest';
  }
  throw new Error(usage);
};

const recoveryTargetArgs = (target) => {
  if (target === 'latest') {
    return [];
  }
  const setting = 'lsn' in target ? `recovery_target_lsn=${target.lsn}` : `recovery_target_time=${target.time.toISOString().replace('T', ' ').replace('Z', '+00')}`;
  return ['-c', setting, '-c', 'recovery_target_action=promote'];
};

const RECOVER_SCRIPT = `set -euo pipefail
mkdir -p "$PGDATA" ${SCRATCH_WAL}
tar -xf /restore/base/immich-base.tar -C "$PGDATA"
mkdir -p "$PGDATA/pg_wal/archive_status"
cp -a /restore/wal/. ${SCRATCH_WAL}/
touch "$PGDATA/recovery.signal"
chown -R postgres:postgres "$PGDATA" ${SCRATCH_WAL}
chmod 700 "$PGDATA"
exec /usr/local/bin/immich-docker-entrypoint.sh postgres -c config_file=/etc/postgresql/postgresql.conf "$@"
`;

const docker = (...args) => run('docker', args);

const waitForPromotion = async (container) => {
  const deadline = Date.now() + PROMOTE_TIMEOUT_MS;
  while (Date.now() < deadline) {
    const running = docker('inspect', '-f', '{{.State.Running}}', container).stdout.trim();
    if (running !== 'true') {
      throw new Error(`Scratch Postgres exited:\n${docker('logs', container).stderr}`);
    }

    const query = run(
      'docker',
      ['exec', container, 'psql', '-X', '-A', '-t', '-U', options['db-user'], '-d', 'postgres', '-c', 'SELECT pg_is_in_recovery()'],
      { allowFailure: true },
    );
    if (query.status === 0 && query.stdout.trim() === 'f') {
      return;
    }
    await sleep(1000);
  }
  throw new Error('Scratch Postgres did not finish recovery in time');
};

const waitForExit = (child, name) =>
  new Promise((resolvePromise, reject) => {
    child.once('error', reject);
    child.once('close', (code) => (code === 0 ? resolvePromise() : reject(new Error(`${name} exited with ${code}`))));
  });

const openSink = () => {
  if (options['dump-to']) {
    const output = createWriteStream(options['dump-to']);
    const gzip = spawn('gzip', ['--rsyncable'], { stdio: ['pipe', 'pipe', 'inherit'] });
    gzip.stdout.pipe(output);
    const written = new Promise((resolvePromise, reject) => {
      output.once('error', reject);
      output.once('finish', resolvePromise);
    });
    return { stdin: gzip.stdin, done: Promise.all([waitForExit(gzip, 'gzip'), written]) };
  }

  const load = spawn('bash', ['-c', options['load-cmd']], { stdio: ['pipe', 'inherit', 'inherit'] });
  return { stdin: load.stdin, done: waitForExit(load, '--load-cmd') };
};

const pipeDump = async (container) => {
  const dump = spawn(
    'docker',
    ['exec', container, 'pg_dump', '-U', options['db-user'], '--clean', '--if-exists', '--', options['db-name']],
    { stdio: ['ignore', 'pipe', 'inherit'] },
  );
  const sink = openSink();
  dump.stdout.pipe(sink.stdin);
  await Promise.all([waitForExit(dump, 'pg_dump'), sink.done]);
};

const main = async () => {
  if (!options['load-cmd'] && !options['dump-to']) {
    throw new Error(usage);
  }

  const target = resolveTarget();
  const archive = listSnapshots('--tag', 'immich-base', '--tag', 'immich-wal');
  const { base, wal } = planWalRestore(archive, target);
  log(`target ${JSON.stringify(target)}: base ${base.short_id ?? base.id} + ${wal.length} WAL snapshot(s)`);

  const work = await mkdtemp(join(process.env.WAL_RESTORE_TMPDIR ?? tmpdir(), 'immich-wal-restore-'));
  const container = `immich-wal-restore-${process.pid}`;
  try {
    restic('restore', base.id, '--target', join(work, 'base'));
    await mkdir(join(work, 'wal'), { recursive: true });
    for (const snapshot of wal) {
      restic('restore', `${snapshot.id}:${dirname(snapshot.paths[0])}`, '--target', join(work, 'wal'));
    }
    await writeFile(join(work, 'recover.sh'), RECOVER_SCRIPT);

    const restoreCommand = `cp ${SCRATCH_WAL}/%f %p 2>/dev/null || cp ${SCRATCH_WAL}/%f.partial %p`;
    docker(
      'run',
      '-d',
      '--name',
      container,
      '--label',
      'futo-wal-e2e',
      '--shm-size',
      '128m',
      '-e',
      'POSTGRES_PASSWORD=scratch',
      '-v',
      `${work}:/restore:ro`,
      '--entrypoint',
      'bash',
      options.image,
      '/restore/recover.sh',
      '-c',
      `restore_command=${restoreCommand}`,
      ...recoveryTargetArgs(target),
    );

    await waitForPromotion(container);
    const recoveryLog = docker('logs', container)
      .stderr.split('\n')
      .filter((line) => /recovery stopping|redo done|last completed transaction|selected new timeline|archive recovery complete/.test(line));
    for (const line of recoveryLog) {
      log(`scratch: ${line.replace(/^.*?LOG:\s+/, '')}`);
    }

    await pipeDump(container);
    log(options['dump-to'] ? `wrote ${options['dump-to']}` : 'loaded the recovered database');
  } finally {
    if (options.keep) {
      log(`kept ${container} and ${work}`);
    } else {
      run('docker', ['rm', '-fv', container], { allowFailure: true });
      await rm(work, { recursive: true, force: true });
    }
  }
};

try {
  await main();
} catch (error) {
  log(String(error?.message ?? error));
  process.exit(1);
}
