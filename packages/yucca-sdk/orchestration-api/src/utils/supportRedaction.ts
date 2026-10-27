import { createHmac, randomBytes } from 'node:crypto';
import { extname } from 'node:path';

const ABSOLUTE_PATH = /^(?:\/|[A-Za-z]:\\)/;
const EMBEDDED_PATH = /(?<=^|[\s"'(=[])(?:\/|[A-Za-z]:\\)[^"\n]*?(?=: |["']|$)/g;
const MAX_EXTENSION_LENGTH = 8;

export type Redactor = (line: string) => string;

export const createPathRedactor = (key: Buffer = randomBytes(32)): Redactor => {
  const placeholder = (path: string) => {
    const digest = createHmac('sha256', key).update(path).digest('hex').slice(0, 12);
    const extension = extname(path.replace(/[/\\]+$/, ''));
    return `<path:${digest}${extension.length <= MAX_EXTENSION_LENGTH ? extension : ''}>`;
  };

  const redactText = (text: string) => text.replaceAll(EMBEDDED_PATH, placeholder);

  const redactValue = (value: unknown): unknown => {
    if (typeof value === 'string') {
      return ABSOLUTE_PATH.test(value) ? placeholder(value) : redactText(value);
    }
    if (Array.isArray(value)) {
      return value.map((item) => redactValue(item));
    }
    if (value && typeof value === 'object') {
      return Object.fromEntries(Object.entries(value).map(([field, item]) => [field, redactValue(item)]));
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
