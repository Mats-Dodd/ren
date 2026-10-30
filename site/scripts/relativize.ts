// Rewrites Astro's absolute /assets/ asset URLs to relative ones so the built site
// works from any subpath (artifact hosting, file://, a /ren/ prefix on the blog).
import { readdirSync, readFileSync, writeFileSync, statSync } from 'node:fs';
import { join, relative, dirname } from 'node:path';

const dist = new URL('../dist', import.meta.url).pathname;
const walk = (d: string): string[] => readdirSync(d).flatMap((f) => {
  const p = join(d, f);
  return statSync(p).isDirectory() ? walk(p) : [p];
});
for (const file of walk(dist)) {
  if (!/\.(html|css)$/.test(file)) continue;
  const rel = relative(dirname(file), join(dist, 'assets')) || '.';
  const src = readFileSync(file, 'utf8');
  const out = src.replaceAll(/(["'(])\/assets\//g, `$1${rel}/`);
  if (out !== src) writeFileSync(file, out);
}
console.log('relativized asset URLs');
