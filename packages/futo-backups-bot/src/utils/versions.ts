import { Messages } from 'src/messages.js';
import { VersionResult } from 'src/repositories/columbo.repository.js';

export const formatVersions = (result: VersionResult | null): string => {
  if (!result) {
    return Messages.versionsUnavailable;
  }
  const lines =
    result.versions.length === 0
      ? [result.unavailableSources.length > 0 ? Messages.versionsUnavailable : Messages.versionsUnknown]
      : [
          Messages.versionsHeader,
          ...result.versions.map(
            ({ component, version, source, lastSeen }) =>
              `• ${component}: ${version} (${source}${lastSeen ? `; last seen ${lastSeen}` : ''})`,
          ),
        ];
  if (result.unavailableSources.length > 0) {
    lines.push(`Unavailable telemetry: ${result.unavailableSources.join(', ')}.`);
  }
  if (result.versions.length > 0 && !result.versions.some(({ component }) => component.endsWith('(client)'))) {
    lines.push('Client version: unknown — only service versions were observed.');
  }
  if (result.versions.length > 0 && !result.versions.some(({ component }) => component.endsWith('(service)'))) {
    lines.push(
      result.unavailableSources.includes('metrics')
        ? 'Service versions: unknown — metrics lookup unavailable.'
        : 'Service versions: unknown — no service versions were observed.',
    );
  }
  return lines.join('\n');
};
