import { ConfigUpdateRequestDto } from './config.dto.js';

describe(ConfigUpdateRequestDto.name, () => {
  it.each([1, 16, 128, null])('accepts a connections override of %s', (connections) => {
    expect(ConfigUpdateRequestDto.schema.safeParse({ connections }).success).toBe(true);
  });

  it.each([0, -1, 129, 2.5, '8'])('rejects a connections override of %s', (connections) => {
    expect(ConfigUpdateRequestDto.schema.safeParse({ connections }).success).toBe(false);
  });

  it('accepts a request that leaves the override untouched', () => {
    expect(ConfigUpdateRequestDto.schema.safeParse({ bandwidth: { bytesPerSec: 0 } }).success).toBe(true);
  });
});
