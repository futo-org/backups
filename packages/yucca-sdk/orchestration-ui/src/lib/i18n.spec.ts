import { setYuccaLanguage } from '$lib/i18n';
import { get } from 'svelte/store';
import { gt, locale } from 'svelte-i18n-lingui';
import { describe, expect, it } from 'vitest';

const configureName = () =>
  gt({ message: 'Configure {name}', values: { name: 'Photos' } });

describe('setYuccaLanguage', () => {
  it('falls back to English for a language without a catalogue', async () => {
    await setYuccaLanguage('xx');
    expect(get(locale)).toBe('en');
    expect(configureName()).toBe('Configure Photos');
  });

  it('loads the catalogue for a supported language', async () => {
    await setYuccaLanguage('en-XA');
    expect(get(locale)).toBe('en-XA');
    expect(configureName()).toBe('Test String Photos');
  });
});
