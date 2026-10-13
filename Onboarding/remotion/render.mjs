// Renders every clip × theme to Resources/Onboarding/<id>.mp4 (H.264, yuv420p, no audio).
//   npm run render                      all clips
//   npm run render -- recall            only ids containing "recall"
//   npm run render -- --stills 0,90     PNG stills into out/ instead of videos
import {bundle} from '@remotion/bundler';
import {getCompositions, renderMedia, renderStill} from '@remotion/renderer';
import {statSync} from 'node:fs';
import {dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const outDir = join(here, '../../Resources/Onboarding');
const args = process.argv.slice(2);
const stillsAt = args.includes('--stills') ? args[args.indexOf('--stills') + 1].split(',').map(Number) : null;
const filter = args.find((a, i) => !a.startsWith('--') && args[i - 1] !== '--stills');

const serveUrl = await bundle({entryPoint: join(here, 'src/Root.tsx')});
const comps = (await getCompositions(serveUrl)).filter((c) => !filter || c.id.includes(filter));

for (const composition of comps) {
  if (stillsAt) {
    for (const frame of stillsAt) {
      const output = join(here, 'out', `${composition.id}-${frame}.png`);
      await renderStill({composition, serveUrl, frame: Math.min(frame, composition.durationInFrames - 1), output});
    }
    console.log(`${composition.id}: stills ${stillsAt.join(', ')}`);
    continue;
  }
  const output = join(outDir, `${composition.id}.mp4`);
  await renderMedia({
    composition, serveUrl, codec: 'h264', crf: 18, pixelFormat: 'yuv420p', muted: true, everyNthFrame: 1,
    outputLocation: output,
  });
  console.log(`${composition.id}: ${(statSync(output).size / 1024).toFixed(0)} KB`);
}
