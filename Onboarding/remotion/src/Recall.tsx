import React from 'react';
import {useCurrentFrame} from 'remotion';
import {Hit, PANEL, PlansPreview, RecallPanel} from './RecallPanel';
import {AppWindow, ClipProps, ease, KeyHUD, MenuBar, press, rgba, sp, Stage, typedCount, typeTimes, useTheme} from './ui';

export const RECALL_FRAMES = 240;

const QUERY = 'pricing toggle monthly yearly';
const PASTED = 'Default to yearly, show monthly small.';
const OPEN = 21; // panel springs in as Space goes down
const TIMES = typeTimes(QUERY, 44, 2.6);
const TYPED = TIMES[TIMES.length - 1];
const RESULTS = TIMES[2] + 5; // results replace Recent after a few letters (150 ms debounce)
const DOWN = TYPED + 16;
const ENTER = DOWN + 28;
const PASTE = ENTER + 8;
const UNDO = 216; // pasted line fades so the loop starts clean

const HITS: Hit[] = [
  {kind: 'screenshot', title: 'Pricing — Monthly / Yearly toggle, dark', source: 'Figma', when: '3 days ago', preview: <PlansPreview />, note: 'Compare with Linear’s annual badge before Thursday.', openIn: 'Figma'},
  {kind: 'text', title: PASTED, source: 'Notes', when: 'Today', text: PASTED, openIn: 'Notes'},
  {kind: 'screenshot', title: 'Billing settings, dark mode', source: 'Safari', when: '3 days ago', openIn: 'Safari'},
  {kind: 'screenshot', title: 'Plan picker with annual discount badge', source: 'Arc', when: '1 week ago', openIn: 'Arc'},
  {kind: 'link', title: 'Pricing table component — Stripe Docs', source: 'Safari', when: '3 days ago', openIn: 'Safari'},
  {kind: 'voice', title: '“Default to yearly, show the monthly …', source: 'Voice', when: 'Yesterday', badge: 'at 0:42'},
  {kind: 'video', title: 'Lecture 9 — Pricing & Positioning', source: 'QuickTime', when: '3 weeks ago', badge: 'at 47:20'},
];
const CHIPS: [string, number][] = [['All', 7], ['Images', 3], ['Audio', 1], ['Video', 1], ['Links', 1]];

/** Issue tracker window; the description's last line is where the caret waits. */
const IssueWindow: React.FC<{caretLine: React.ReactNode}> = ({caretLine}) => {
  const T = useTheme();
  return (
    <AppWindow x={36} y={42} w={488} h={262}>
      <div style={{position: 'absolute', left: 104, top: -22, fontSize: 11.5, color: T.text2}}>Daemon › DMN-218</div>
      <div style={{padding: '18px 28px', fontSize: 13, lineHeight: '22px', color: T.text}}>
        <div style={{fontSize: 18, fontWeight: 600, marginBottom: 8}}>Pricing toggle copy</div>
        <div style={{display: 'flex', gap: 6, marginBottom: 14}}>
          {['In Progress', 'Design', 'Oct 16'].map((c) => (
            <span key={c} style={{fontSize: 10.5, color: T.text2, border: `1px solid ${T.divider}`, borderRadius: 10, padding: '1px 8px'}}>{c}</span>
          ))}
        </div>
        <div style={{color: T.text2}}>Decide what the plan toggle shows by default.</div>
        <div style={{color: T.text2}}>From the pricing review:</div>
        <div style={{height: 22}}>{caretLine}</div>
      </div>
    </AppWindow>
  );
};

const Scene: React.FC = () => {
  const T = useTheme();
  const f = useCurrentFrame();

  const n = typedCount(TIMES, f);
  const open = f < ENTER + 2 ? sp(f, OPEN, 260) : 1 - ease(f, ENTER + 2, ENTER + 8);
  const panelA = f < ENTER + 2 ? ease(f, OPEN, OPEN + 6) : open;
  const scale = f < ENTER + 2 ? 0.965 + 0.035 * open : 0.985 + 0.015 * open;
  const blink = Math.floor(f / 15) % 2 === 0;
  const typing = f >= TIMES[0] - 2 && f < TYPED + 10;

  const pasted = ease(f, PASTE, PASTE + 3) * (1 - ease(f, UNDO, UNDO + 14));
  const flash = 1 - ease(f, PASTE + 6, PASTE + 36);
  const writerCaret = (f < OPEN || f >= PASTE) && blink && !(f >= UNDO && f < UNDO + 14);
  const caret = <span style={{display: 'inline-block', width: 1.5, height: 16, background: T.text, verticalAlign: 'middle', marginTop: -2, opacity: writerCaret ? 1 : 0}} />;
  const caretLine = (
    <>
      {pasted > 0 && f < UNDO + 14 && (
        <span style={{opacity: pasted, background: rgba(T.accentRGB, T.selAlpha * flash), borderRadius: 3}}>{PASTED}</span>
      )}
      {caret}
    </>
  );

  const zoom = 0.6;
  return (
    <>
      <MenuBar app="Linear" menus={['File', 'Edit', 'View', 'Issue']} />
      <IssueWindow caretLine={caretLine} />
      {panelA > 0 && (
        <div
          style={{
            position: 'absolute', left: (560 - PANEL.w * zoom) / 2, top: 26, width: PANEL.w * zoom, height: PANEL.h * zoom,
            opacity: panelA, transform: `scale(${scale})`, zIndex: 45,
          }}
        >
          <div style={{zoom}}>
            <RecallPanel
              query={n > 0 ? <span style={{whiteSpace: 'pre'}}>{QUERY.slice(0, n)}</span> : null}
              caret={typing || blink}
              recent={1 - ease(f, RESULTS - 3, RESULTS + 1)}
              hits={HITS}
              rowIn={(i) => ease(f, RESULTS + i * 2, RESULTS + i * 2 + 8)}
              selection={f >= DOWN ? 1 : 0}
              chips={CHIPS}
              pasteInto="Linear"
              enterLit={press(f, ENTER, ENTER + 6)}
            />
          </div>
        </div>
      )}
      <KeyHUD compact keys={['⌃', '⌥', 'Space']} label="Recall" enter={4} exit={34} downs={[11, 15, OPEN - 1]} ups={[29, 29, 29]} />
      <KeyHUD compact keys={['↓', '↵']} enter={TYPED + 4} exit={ENTER + 12} downs={[DOWN, ENTER]} ups={[DOWN + 7, ENTER + 6]} />
    </>
  );
};

export const Recall: React.FC<ClipProps> = ({theme}) => (
  <Stage theme={theme}>
    <Scene />
  </Stage>
);
