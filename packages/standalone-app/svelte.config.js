import adapter from '@sveltejs/adapter-static';
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte';
import packageJson from './package.json' with { type: 'json' };

/** @type {import('@sveltejs/kit').Config} */
const config = {
  preprocess: vitePreprocess(),

  kit: {
    adapter: adapter({ fallback: 'index.html' }),
    version: { name: packageJson.version },
  },
};

export default config;
