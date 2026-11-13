import BackupItem from '../../../test-mocks/BackupItemTestContext.svelte';
import type { LocalRepositoryDto } from '$lib/fetch-client';
import { render } from 'svelte/server';
import { describe, expect, it, vi } from 'vitest';

vi.mock('$lib/fetch-client');

const repository = (configuration?: { paths: string[] }) =>
  ({
    id: 'repository-1',
    name: 'Photos',
    worm: false,
    metrics: { sizeBytes: 0 },
    configuration,
  }) as unknown as LocalRepositoryDto;

const renderItem = (configuration?: { paths: string[] }) =>
  render(BackupItem, { props: { repository: repository(configuration) } }).body;

describe('BackupItem', () => {
  it('flags a local repository without any folders', () => {
    expect(renderItem({ paths: [] })).toContain('No folders added');
  });

  it('shows the backup status once folders are added', () => {
    const body = renderItem({ paths: ['/photos'] });

    expect(body).not.toContain('No folders added');
    expect(body).toContain('Never backed up');
  });

  it('does not flag a repository without a local configuration', () => {
    expect(renderItem()).not.toContain('No folders added');
  });
});
