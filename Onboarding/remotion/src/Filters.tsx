import React from 'react';
import {useCurrentFrame} from 'remotion';
import {Hit, PANEL, RecallPanel, TokenQuery} from './RecallPanel';
import {AppWindow, ClipProps, ease, KeyHUD, MenuBar, sp, Stage, typedCount, typeTimes, useTheme} from './ui';

export const FILTERS_FRAMES = 240;

const QUERY = 'from:safari last week flight';
const OPEN = 21;
const TIMES = typeTimes(QUERY, 42, 2.6);
const TOKEN1 = TIMES[11]; // the space after "from:safari"
const TOKEN2 = TIMES[21]; // the space after "last week"
const DONE = TIMES[TIMES.length - 1];
const ESC = DONE + 62;

const FlightPreview: React.FC = () => {
  const T = useTheme();
  return (
    <div style={{height: 140, borderRadius: 8, overflow: 'hidden', background: T.thumbLight, border: `1px solid ${T.border}`, color: '#1E1A17'}}>
      <div style={{height: 14, background: '#E6E0D6', display: 'flex', alignItems: 'center', gap: 4, padding: '0 6px'}}>
        <div style={{width: 5, height: 5, borderRadius: 3, background: '#C9C4BC'}} />
        <div style={{width: 5, height: 5, borderRadius: 3, background: '#C9C4BC'}} />
        <div style={{flex: 1, height: 6, borderRadius: 3, background: 'rgba(255,255,255,0.9)', marginLeft: 4}} />
      </div>
      <div style={{padding: '12px 16px'}}>
        <div style={{fontSize: 9, letterSpacing: 1, color: '#6B625A', fontWeight: 600}}>BOOKING CONFIRMED</div>
        <div style={{display: 'flex', alignItems: 'baseline', gap: 10, marginTop: 8}}>
          <span style={{fontSize: 22, fontWeight: 600}}>LHR</span>
          <span style={{fontSize: 13, color: '#8E857B'}}>→</span>
          <span style={{fontSize: 22, fontWeight: 600}}>SFO</span>
        </div>
        <div style={{fontSize: 10, color: '#6B625A', marginTop: 6}}>Wed 14 Oct · 11:20 · Seat 23A</div>
        <div style={{fontSize: 10, color: '#6B625A', marginTop: 2}}>Ref K7Q2PX</div>
      </div>
    </div>
  );
};

const FLIGHT: Hit = {kind: 'link', title: 'Flight confirmation, LHR → SFO', source: 'Safari', when: '5 days ago', preview: <FlightPreview />, openIn: 'Safari'};
const ALL: Hit[] = [
  {kind: 'link', title: 'DMN-214 Recall loses focus on paste', source: 'Safari', when: 'Today', openIn: 'Safari'},
  {kind: 'screenshot', title: 'Billing settings, dark mode', source: 'Safari', when: '3 days ago', openIn: 'Safari'},
  {kind: 'link', title: 'Pricing table component — Stripe Docs', source: 'Safari', when: '3 days ago', openIn: 'Safari'},
  FLIGHT,
  {kind: 'link', title: 'Hotel booking, Lisbon', source: 'Safari', when: '2 weeks ago', openIn: 'Safari'},
  {kind: 'link', title: 'Visa requirements — United States', source: 'Safari', when: '3 weeks ago', openIn: 'Safari'},
];

// Each stage is the result list (indices into ALL) once a filter or the last word lands.
const STAGES: {at: number; rows: number[]; chips: [string, number][]}[] = [
  {at: TOKEN1 + 5, rows: [0, 1, 2, 3, 4, 5], chips: [['All', 6], ['Images', 1], ['Links', 5]]},
  {at: TOKEN2 + 5, rows: [1, 2, 3], chips: [['All', 3], ['Images', 1], ['Links', 2]]},
  {at: DONE + 5, rows: [3], chips: [['All', 1], ['Links', 1]]},
];

const NotesWindow: React.FC<{caret: boolean}> = ({caret}) => {
  const T = useTheme();
  return (
    <AppWindow x={60} y={54} w={360} h={230} title="Notes">
      <div style={{padding: '20px 26px', fontSize: 13, lineHeight: '24px', color: T.text}}>
        <div style={{fontSize: 16, fontWeight: 700, marginBottom: 6}}>Offsite travel</div>
        <div>Lisbon first, then SF for the offsite.</div>
        <div>Flight number for the hotel form:<span style={{display: 'inline-block', width: 1.5, height: 15, background: T.text, verticalAlign: 'middle', marginLeft: 3, opacity: caret ? 1 : 0}} /></div>
      </div>
    </AppWindow>
  );
};

const Scene: React.FC = () => {
  const f = useCurrentFrame();
  const n = typedCount(TIMES, f);
  const open = f < ESC + 2 ? sp(f, OPEN, 260) : 1 - ease(f, ESC + 2, ESC + 8);
  const panelA = f < ESC + 2 ? ease(f, OPEN, OPEN + 6) : open;
  const scale = f < ESC + 2 ? 0.965 + 0.035 * open : 0.985 + 0.015 * open;
  const blink = Math.floor(f / 15) % 2 === 0;

  // Rows glide from their slot in the previous stage to the new one; dropped rows fade out.
  const s = STAGES.reduce((cur, st, i) => (f >= st.at ? i : cur), -1);
  const cur = s >= 0 ? STAGES[s] : null;
  const prev = s > 0 ? STAGES[s - 1] : null;
  const t = cur ? ease(f, cur.at, cur.at + 9) : 0;
  const rowIn = (i: number) => {
    if (!cur) return 0;
    const inCur = cur.rows.includes(i);
    if (!prev) return inCur ? ease(f, cur.at + cur.rows.indexOf(i) * 2, cur.at + cur.rows.indexOf(i) * 2 + 8) : 0;
    const inPrev = prev.rows.includes(i);
    return inCur && inPrev ? 1 : inCur ? t : inPrev ? 1 - ease(f, cur.at, cur.at + 5) : 0;
  };
  const rowY = (i: number) => {
    const a = prev?.rows.indexOf(i) ?? -1;
    const b = cur?.rows.indexOf(i) ?? -1;
    return a >= 0 && b >= 0 ? a + (b - a) * t : Math.max(a, b);
  };
  const selection = cur ? cur.rows[0] : 0;

  return (
    <>
      <MenuBar app="Notes" menus={['File', 'Edit', 'Format', 'View']} />
      <NotesWindow caret={(f < OPEN || f > ESC + 4) && blink} />
      {panelA > 0 && (
        <div style={{position: 'absolute', left: (560 - PANEL.w * 0.6) / 2, top: 26, width: PANEL.w * 0.6, height: PANEL.h * 0.6, opacity: panelA, transform: `scale(${scale})`, zIndex: 45}}>
          <div style={{zoom: 0.6}}>
            <RecallPanel
              query={n > 0 ? (
                <TokenQuery
                  text={QUERY.slice(0, n)}
                  tokens={[
                    {from: 0, to: 11, a: ease(f, TOKEN1, TOKEN1 + 6)},
                    {from: 12, to: 21, a: ease(f, TOKEN2, TOKEN2 + 6)},
                  ]}
                />
              ) : null}
              caret={(f >= TIMES[0] - 2 && f < DONE + 10) || blink}
              recent={1 - ease(f, STAGES[0].at - 3, STAGES[0].at + 1)}
              hits={ALL}
              rowIn={rowIn}
              rowY={rowY}
              previewIn={cur ? ease(f, cur.at, cur.at + 6) : 0}
              selection={selection}
              chips={cur?.chips ?? STAGES[0].chips}
              pasteInto="Notes"
            />
          </div>
        </div>
      )}
      <KeyHUD compact keys={['⌃', '⌥', 'Space']} label="Recall" enter={4} exit={34} downs={[11, 15, OPEN - 1]} ups={[29, 29, 29]} />
      <KeyHUD compact keys={['Esc']} label="Close" enter={ESC - 12} exit={ESC + 12} downs={[ESC]} ups={[ESC + 6]} />
    </>
  );
};

export const Filters: React.FC<ClipProps> = ({theme}) => (
  <Stage theme={theme}>
    <Scene />
  </Stage>
);
