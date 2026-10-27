import spec from '../../openapi-specs.json' with { type: 'json' };

describe('job schema ids', () => {
  it('cannot collide with a host application that documents its own job enums', () => {
    const schemas = Object.keys(spec.components.schemas);

    expect(schemas).toEqual(expect.arrayContaining(['YuccaJobName', 'YuccaJobStatus']));
    expect(schemas).not.toEqual(expect.arrayContaining(['JobName']));
    expect(schemas).not.toEqual(expect.arrayContaining(['JobStatus']));
  });
});
