import { defineConfig } from 'astro/config';
import mdx from '@astrojs/mdx';
import stylex from '@stylexjs/unplugin';
import path from 'node:path';

export default defineConfig({
  integrations: [mdx()],
  build: { format: 'file', assets: 'assets' },
  vite: {
    plugins: [
      stylex.vite({
        useCSSLayers: false, // specificity-based, so host or blog CSS can't override tokens
        dev: process.env.NODE_ENV === 'development',
        runtimeInjection: false,
        unstable_moduleResolution: { type: 'commonJS', rootDir: path.resolve('.') },
      }),
    ],
  },
});
