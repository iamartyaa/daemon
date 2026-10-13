import React from 'react';
import {useCurrentFrame} from 'remotion';
import {
  AppWindow, ClipProps, Cursor, ease, glowAt, KeptBody, KeyHUD, MenuBar, rgba, sp, Stage, Thumb, ToastCard, useTheme,
} from './ui';

export const KEEP_TEXT_FRAMES = 210;

/** Notes window with the four lines from the onboarding illustration. `line3` renders the line that gets selected. */
export const NotesWindow: React.FC<{line3?: React.ReactNode}> = ({line3}) => {
  const T = useTheme();
  return (
    <AppWindow x={30} y={62} w={300} h={226} title="Notes">
      <div style={{padding: '20px 26px', fontSize: 13, lineHeight: '24px', color: T.text}}>
        <div style={{fontSize: 16, fontWeight: 700, marginBottom: 6}}>Pricing page review</div>
        <div>Keep the plan cards simple.</div>
        <div>{line3 ?? 'Default to yearly, show monthly small.'}</div>
        <div>Annual discount badge on Pro only.</div>
      </div>
    </AppWindow>
  );
};

const Scene: React.FC = () => {
  const T = useTheme();
  const f = useCurrentFrame();

  const sel = ease(f, 34, 66); // highlight sweep
  const selAlpha = 1 - ease(f, 168, 182); // deselect before the loop
  const approach = ease(f, 8, 30);
  const dx = -46 * (1 - approach) - 1 + 14 * ease(f, 72, 96);
  const dy = 34 * (1 - approach) + 18 * ease(f, 72, 96);
  const cursorA = ease(f, 6, 16) * (1 - ease(f, 150, 162));

  const toast = f < 135 ? sp(f, 90) : 1 - ease(f, 135, 143);

  const line3 = (
    <span style={{position: 'relative', display: 'inline-block'}}>
      <span
        style={{
          position: 'absolute', left: -2, top: 2, bottom: 2, width: `calc(${sel * 100}% + ${sel > 0 ? 4 : 0}px)`,
          background: rgba(T.accentRGB, T.selAlpha * selAlpha), borderRadius: 3,
        }}
      />
      <span style={{position: 'relative'}}>Default to yearly, show monthly small.</span>
      <span style={{position: 'absolute', left: `${sel * 100}%`, top: 12}}>
        <Cursor x={dx} y={dy} kind="ibeam" opacity={cursorA} />
      </span>
    </span>
  );

  return (
    <>
      <MenuBar app="Notes" menus={['File', 'Edit', 'Format', 'View']} glow={glowAt(f, 89)} />
      <NotesWindow line3={line3} />
      <ToastCard a={toast}>
        <KeptBody thumb={<Thumb kind="text" w={44} h={44} radius={7} />} subtitle="from Notes" progress={Math.min(1, Math.max(0, (f - 90) / 45))} />
      </ToastCard>
      <KeyHUD keys={['⌃', '⌥', 'S']} label="Keep" enter={70} exit={126} downs={[80, 84, 88]} ups={[104, 104, 104]} />
    </>
  );
};

export const KeepText: React.FC<ClipProps> = ({theme}) => (
  <Stage theme={theme}>
    <Scene />
  </Stage>
);
