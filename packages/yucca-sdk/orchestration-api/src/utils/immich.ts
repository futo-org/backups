import type { ImmichIntegration } from '../moduleConfig.js';

type ImmichLibrary = ImmichIntegration['libraries'][number];

export const getSelectedImmichLibraries = (selected: string[], libraries: ImmichLibrary[]) =>
  selected.includes('all') ? libraries : libraries.filter(({ id }) => selected.includes(id));
