import { schemaFromCode } from '@immich/sql-tools';
import './index.js';

describe('SDK entry point', () => {
  it('keeps its database schema out of a host that imports it', () => {
    const { enums, tables } = schemaFromCode();

    expect([...enums, ...tables].map(({ name }) => name).filter((name) => name.startsWith('futo_backups_'))).toEqual(
      [],
    );
  });
});
