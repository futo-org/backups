import { createHmac, randomBytes } from 'node:crypto';
import { extname } from 'node:path';

const ABSOLUTE_PATH = /^(?:\/|[A-Za-z]:\\)/;
// Quotes, apostrophes and ": " are all legal in file names, so nothing inside a name reliably ends it. An
// embedded path is redacted through the last ": " (where Go appends the error reason) or to the end of the
// message, at the cost of also hiding any text between the path and that point.
const EMBEDDED_PATH = /(?<=^|[\s"'(=[])(?:\/|[A-Za-z]:\\)(?:.*(?=: )|.*)/g;
const PATH_FIELDS = new Set(['item', 'current_files', 'path', 'paths', 'name', 'target', 'excludes']);
const MAX_EXTENSION_LENGTH = 8;

export type Redactor = (line: string) => string;

export const createPathRedactor = (key: Buffer = randomBytes(32)): Redactor => {
  const placeholder = (path: string) => {
    const digest = createHmac('sha256', key).update(path).digest('hex').slice(0, 12);
    const extension = extname(path.replace(/["'/\\]+$/, ''));
    return `<path:${digest}${extension.length <= MAX_EXTENSION_LENGTH ? extension : ''}>`;
  };

  const redactText = (text: string) => text.replaceAll(EMBEDDED_PATH, placeholder);

  const redactValue = (value: unknown, isPath = false): unknown => {
    if (typeof value === 'string') {
      return isPath || ABSOLUTE_PATH.test(value) ? placeholder(value) : redactText(value);
    }
    if (Array.isArray(value)) {
      return value.map((item) => redactValue(item, isPath));
    }
    if (value && typeof value === 'object') {
      return Object.fromEntries(
        Object.entries(value).map(([field, item]) => [field, redactValue(item, PATH_FIELDS.has(field))]),
      );
    }
    return value;
  };

  return (line) => {
    if (line.startsWith('{') || line.startsWith('[')) {
      try {
        return JSON.stringify(redactValue(JSON.parse(line)));
      } catch {
        return redactText(line);
      }
    }
    return redactText(line);
  };
};
