import { readable } from 'svelte/store';

export const now = readable(Date.now(), (set) => {
  set(Date.now());
  const interval = setInterval(() => set(Date.now()), 1000);
  return () => clearInterval(interval);
});
