import spec from '../../openapi-specs.json' with { type: 'json' };

type Schema = {
  type?: string;
  format?: string;
  properties?: Record<string, Schema>;
  items?: Schema;
  anyOf?: Schema[];
  oneOf?: Schema[];
  allOf?: Schema[];
};

const unformattedNumbers = (name: string, schema: Schema, path = ''): string[] => [
  ...(schema.type === 'number' && !schema.format ? [`${name}${path}`] : []),
  ...Object.entries(schema.properties ?? {}).flatMap(([key, value]) =>
    unformattedNumbers(name, value, `${path}.${key}`),
  ),
  ...(schema.items ? unformattedNumbers(name, schema.items, `${path}[]`) : []),
  ...[...(schema.anyOf ?? []), ...(schema.oneOf ?? []), ...(schema.allOf ?? [])].flatMap((variant) =>
    unformattedNumbers(name, variant, path),
  ),
];

describe('OpenAPI document', () => {
  it('gives every non-integer number a format, as hosts that merge it into their own document require', () => {
    const schemas = spec.components.schemas as Record<string, Schema>;

    expect(Object.entries(schemas).flatMap(([name, schema]) => unformattedNumbers(name, schema))).toEqual([]);
  });
});
