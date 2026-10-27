import { createPathRedactor } from './supportRedaction.js';

const key = Buffer.alloc(32, 1);

describe(createPathRedactor.name, () => {
  const redact = createPathRedactor(key);

  it('replaces every path in a restic JSON line and keeps the rest', () => {
    const line = JSON.stringify({
      message_type: 'verbose_status',
      action: 'new',
      item: '/photos/My Trip/IMG_0001.jpg',
      data_size: 3,
    });

    const redacted = JSON.parse(redact(line));

    expect(redacted).toMatchObject({ message_type: 'verbose_status', action: 'new', data_size: 3 });
    expect(redacted.item).toMatch(/^<path:[0-9a-f]{12}\.jpg>$/);
  });

  it('redacts paths inside arrays and nested messages', () => {
    const line = JSON.stringify({
      message_type: 'status',
      current_files: ['/photos/a.heic', '/photos/b.mov'],
      error: { message: 'open /photos/secret album/c.png: permission denied' },
    });

    const redacted = redact(line);

    expect(redacted).not.toContain('/photos');
    expect(redacted).not.toContain('secret album');
    expect(redacted).toContain(': permission denied');
  });

  it('gives the same path the same placeholder within a session', () => {
    const first = JSON.parse(redact(JSON.stringify({ item: '/photos/a.jpg' }))).item;
    const second = JSON.parse(redact(JSON.stringify({ item: '/photos/a.jpg' }))).item;

    expect(first).toBe(second);
    expect(createPathRedactor(Buffer.alloc(32, 2))(JSON.stringify({ item: '/photos/a.jpg' }))).not.toContain(first);
  });

  it('redacts paths in plain-text stderr lines but leaves backend URLs alone', () => {
    const retry =
      'Load(<data/0123abcd>, 0, 0) returned error, retrying after 1.4s: Head "https://:***@rest.example/repo/config": EOF';

    expect(redact(retry)).toBe(retry);
    expect(redact('error: lstat /photos/My Trip/b.jpg: no such file or directory')).toMatch(
      /^error: lstat <path:[0-9a-f]{12}\.jpg>: no such file or directory$/,
    );
  });

  it('keeps Windows paths out of the stream', () => {
    expect(redact(JSON.stringify({ item: String.raw`C:\Users\me\a.txt` }))).not.toContain('Users');
  });
});
