export const toRunsDraft = (remainingRuns: number) =>
  remainingRuns || undefined;

export const nextRunsDraft = (
  draft: number | undefined,
  synced: number | undefined,
  remainingRuns: number,
) => (draft === synced ? toRunsDraft(remainingRuns) : draft);
