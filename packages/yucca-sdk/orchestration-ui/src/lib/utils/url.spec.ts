import { toOpenableUrl } from '$lib/utils/url';
import { describe, expect, it } from 'vitest';

describe('toOpenableUrl', () => {
  it.each([
    'https://idp.test/authorize?ticket=1',
    'http://localhost:8092/device',
  ])('accepts %s', (url) => {
    expect(toOpenableUrl(url)).toBe(url);
  });

  it.each([
    'javascript:alert(1)',
    ' JavaScript:alert(1)',
    '\tjava\nscript:alert(1)',
    'data:text/html,<script>alert(1)</script>',
    'vbscript:msgbox(1)',
    'file:///etc/passwd',
    '/relative/path',
  ])('rejects %j', (url) => {
    expect(() => toOpenableUrl(url)).toThrow();
  });
});
