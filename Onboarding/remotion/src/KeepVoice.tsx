import React from 'react';
import {random, useCurrentFrame} from 'remotion';
import {NotesWindow} from './KeepText';
import {
  ClipProps, ease, glowAt, KeptBody, KeyHUD, ListeningBody, MenuBar, sp, Stage, Thumb, ToastCard, useTheme,
} from './ui';

export const KEEP_VOICE_FRAMES = 240;

const DOWN = 30; // S goes down; ⌃ and ⌥ a little earlier
const HOLD = 12; // 0.4 s until it counts as a hold
const LISTEN = DOWN + HOLD;
const UP = 160;
const BARS = 26; // ToastModel.barCount

// Speech-like level for sample n: syllables from a slow sine, texture from noise.
const speech = (n: number) => {
  const syllable = 0.55 + 0.45 * Math.sin(n * 0.55) * Math.sin(n * 0.17 + 1);
  return Math.min(1, Math.max(0.08, 0.12 + 0.88 * syllable * (0.45 + 0.55 * random(`v${n}`))));
};

/** Levels scroll left like the mic meter (~20 samples a second); bars before the first sample sit at 0.08. */
const levelsAt = (f: number) => {
  const t = Math.max(0, f - LISTEN) * (20 / 30);
  const k = Math.floor(t);
  const frac = t - k;
  return Array.from({length: BARS}, (_, i) => {
    const n = k - (BARS - 1 - i);
    const a = n < 0 ? 0.08 : speech(n);
    const b = n + 1 < 0 ? 0.08 : speech(n + 1);
    return a + (b - a) * frac;
  });
};

/** Fills over the 0.4 s hold, then gains a dot and becomes the Daemon mark. */
const HoldRing: React.FC<{p: number; dot: number}> = ({p, dot}) => {
  const T = useTheme();
  const c = 2 * Math.PI * 8;
  return (
    <svg width={20} height={20} viewBox="0 0 20 20" style={{marginLeft: 8}}>
      <circle cx={10} cy={10} r={8} fill="none" stroke={T.kbdBorder} strokeWidth={2} />
      <circle cx={10} cy={10} r={8} fill="none" stroke={T.accent} strokeWidth={2} strokeLinecap="round"
        strokeDasharray={c} strokeDashoffset={c * (1 - p)} transform="rotate(-90 10 10)" />
      <circle cx={10} cy={10} r={3 * dot} fill={T.accent} />
    </svg>
  );
};

const Scene: React.FC = () => {
  const T = useTheme();
  const f = useCurrentFrame();
  const hold = ease(f, DOWN, LISTEN);
  const toast = f < 207 ? sp(f, LISTEN) : 1 - ease(f, 207, 215);
  const listenA = 1 - ease(f, UP, UP + 6);
  const keptA = ease(f, UP + 2, UP + 10);
  const seconds = Math.min(4, 1 + Math.floor(Math.max(0, f - LISTEN) / 30));

  return (
    <>
      <MenuBar app="Notes" menus={['File', 'Edit', 'Format', 'View']} glow={glowAt(f, UP + 1)} />
      <NotesWindow />
      <ToastCard a={toast}>
        {listenA > 0 && <div style={{position: 'absolute', inset: 0, opacity: listenA}}><ListeningBody levels={levelsAt(f)} seconds={seconds} /></div>}
        {keptA > 0 && (
          <div style={{position: 'absolute', inset: 0, opacity: keptA}}>
            <KeptBody thumb={<Thumb kind="voice" w={44} h={44} radius={7} />} subtitle="Voice note" progress={Math.min(1, Math.max(0, (f - UP - 2) / 45))} />
          </div>
        )}
      </ToastCard>
      <KeyHUD
        keys={['⌃', '⌥', 'S']} enter={10} exit={UP + 12} downs={[DOWN - 8, DOWN - 4, DOWN]} ups={[UP, UP, UP]}
        extra={
          <>
            <HoldRing p={hold} dot={ease(f, LISTEN, LISTEN + 5)} />
            <span style={{marginLeft: 7, fontSize: 13, fontWeight: 600, color: T.text}}>Hold to speak</span>
          </>
        }
      />
    </>
  );
};

export const KeepVoice: React.FC<ClipProps> = ({theme}) => (
  <Stage theme={theme}>
    <Scene />
  </Stage>
);
