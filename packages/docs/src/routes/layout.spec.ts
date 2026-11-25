import { afterNavigate } from '$app/navigation';
import { page } from '$app/state';
import type { AfterNavigate } from '@sveltejs/kit';
import { render } from 'svelte/server';
import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest';
import Layout from './+layout.svelte';

vi.mock('$app/navigation', () => ({
  afterNavigate: vi.fn(),
  beforeNavigate: vi.fn(),
  goto: vi.fn(),
}));

vi.mock('$app/state', () => ({
  page: { url: new URL('https://docs.futo.cloud/guides/account') },
}));

describe('docs hash navigation', () => {
  let scrollTop: number;
  let headingId: string;

  const navigate = (hash: string, type: AfterNavigate['type'] = 'enter') => {
    const url = new URL(`https://docs.futo.cloud/guides/account${hash}`);
    Object.assign(page, { url });
    const navigation = {
      type,
      from: null,
      to: { url, params: {}, route: { id: '/guides/account' }, scroll: null },
      willUnload: false,
      complete: Promise.resolve(),
    } as AfterNavigate;

    const pending = vi.mocked(afterNavigate).mock.calls.map(([callback]) => callback(navigation));
    scrollTop = 0;
    return Promise.all(pending);
  };

  beforeEach(async () => {
    vi.clearAllMocks();
    await render(Layout, {
      props: {
        data: {
          pages: [],
          docs: [],
        },
      },
    });
    expect(afterNavigate).toHaveBeenCalled();
    scrollTop = 300;
    headingId = 'where-your-data-is-stored';
    vi.stubGlobal('document', {
      getElementById: (id: string) =>
        id === headingId
          ? {
              scrollIntoView: () => {
                scrollTop = 300;
              },
            }
          : null,
    });
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  test.each(['enter', 'link', 'goto'] as const)('restores the heading after the shell resets scroll on %s', async (type) => {
    const completed = navigate('#where-your-data-is-stored', type);
    expect(scrollTop).toBe(0);
    await completed;
    expect(scrollTop).toBe(300);
  });

  test.each(['', '#missing', '#invalid%'])('leaves the shell scroll reset alone for %s', async (hash) => {
    await navigate(hash);
    expect(scrollTop).toBe(0);
  });

  test('decodes the fragment before finding the heading', async () => {
    headingId = 'data storage';
    await navigate('#data%20storage');
    expect(scrollTop).toBe(300);
  });

  test('does not restore an anchor after a newer navigation', async () => {
    const first = navigate('#where-your-data-is-stored');
    const second = navigate('');
    await Promise.all([first, second]);
    expect(scrollTop).toBe(0);
  });
});
