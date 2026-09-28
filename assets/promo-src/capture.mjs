// Usage: node capture.mjs stills 0.5,2.5,...  |  node capture.mjs video <fps> <out.mp4>
import { chromium } from 'playwright-core';
import { spawn } from 'node:child_process';
const [mode, arg, out] = process.argv.slice(2);
const browser = await chromium.launch({ executablePath: '/usr/bin/chromium', args: ['--force-color-profile=srgb'] });
const page = await browser.newPage({ viewport: { width: 1920, height: 1080 } });
await page.goto(new URL('./index.html', import.meta.url).href);
await page.waitForFunction(() => window.__ready);
const errs = []; page.on('pageerror', e => errs.push(e.message));
if (mode === 'stills') {
  for (const t of arg.split(',')) {
    await page.evaluate(t => render(t), +t);
    await page.screenshot({ path: `stills/t${t}.png` });
  }
} else {
  const fps = +arg, n = Math.round(15 * fps);
  const ff = spawn('ffmpeg', ['-y', '-loglevel', 'error', '-f', 'image2pipe', '-framerate', String(fps), '-i', '-',
    '-c:v', 'libx264', '-preset', 'slow', '-crf', '16', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', out], { stdio: ['pipe', 'inherit', 'inherit'] });
  for (let i = 0; i < n; i++) {
    await page.evaluate(t => render(t), i / fps);
    const buf = await page.screenshot({ type: 'png' });
    if (!ff.stdin.write(buf)) await new Promise(r => ff.stdin.once('drain', r));
  }
  ff.stdin.end();
  await new Promise(r => ff.on('close', r));
}
if (errs.length) console.log('PAGE ERRORS', errs);
await browser.close();
