// Renders the .dc.html artboards as standalone browser pages, one per theme.
// The canvas runtime is not present here, so the {{theme}} hole is substituted
// and the custom elements are given block/none display.
import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const boards = join(here, '..', 'artboards');
const shim = `<style>
  html, body { height: 100%; }
  x-dc { display: block; height: 100%; }
  helmet { display: none; }
</style>
<script>
  // Lets the render script read the real content height back out of --dump-dom.
  addEventListener('load', () => {
    document.title = 'H' + document.documentElement.scrollHeight;
  });
</script>`;

for (const file of readdirSync(boards).filter((f) => f.endsWith('.dc.html'))) {
  const src = readFileSync(join(boards, file), 'utf8');
  for (const theme of ['light', 'dark']) {
    const out = src
      .replace('<script src="./support.js"></script>', shim)
      .replaceAll('{{theme}}', theme);
    writeFileSync(join(here, `${file.replace('.dc.html', '')}-${theme}.html`), out);
  }
}
console.log('previews written');
