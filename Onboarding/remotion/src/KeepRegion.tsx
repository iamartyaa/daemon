import React from 'react';
import {useCurrentFrame} from 'remotion';
import {
  AppWindow, ClipProps, Cursor, ease, glowAt, KeptBody, KeyHUD, MenuBar, sp, Stage, Thumb, ToastCard, useTheme,
} from './ui';
import {font} from './theme';

export const KEEP_REGION_FRAMES = 225;

const BARS = [0.42, 0.55, 0.48, 0.62, 0.58, 0.74, 0.69, 0.9];

/** The small chart that gets captured; also drawn into the toast thumbnail. */
const Chart: React.FC<{w: number; h: number}> = ({w, h}) => {
  const T = useTheme();
  return (
    <svg width={w} height={h} viewBox="0 0 220 124" preserveAspectRatio="none" style={{display: 'block'}}>
      <rect x={0} y={0} width={220} height={124} fill={T.appWindow} />
      <text x={14} y={22} fontSize={11} fontWeight={600} fill={T.text} fontFamily={font.ui}>Weekly signups</text>
      <text x={206} y={22} fontSize={10} fill={T.text2} fontFamily={font.ui} textAnchor="end">+12%</text>
      {[54, 76, 98].map((y) => <line key={y} x1={14} x2={206} y1={y} y2={y} stroke={T.divider} strokeWidth={0.75} />)}
      {BARS.map((v, i) => {
        const bh = v * 70;
        return <rect key={i} x={18 + i * 24} y={110 - bh} width={14} height={bh} rx={2.5} fill={i === BARS.length - 1 ? T.accent : T.text3} opacity={i === BARS.length - 1 ? 1 : 0.45} />;
      })}
      <line x1={14} x2={206} y1={110.5} y2={110.5} stroke={T.text3} strokeWidth={0.75} />
    </svg>
  );
};

const StatTile: React.FC<{label: string; value: string}> = ({label, value}) => {
  const T = useTheme();
  return (
    <div style={{border: `1px solid ${T.divider}`, borderRadius: 8, padding: '9px 12px', marginBottom: 10}}>
      <div style={{fontSize: 10.5, color: T.text2}}>{label}</div>
      <div style={{fontSize: 17, fontWeight: 600, marginTop: 2, color: T.text}}>{value}</div>
    </div>
  );
};

// Stage coordinates of the chart card and the region dragged around it.
const CHART = {x: 60, y: 124, w: 220, h: 124};
const FROM = {x: CHART.x - 8, y: CHART.y - 8};
const TO = {x: CHART.x + CHART.w + 8, y: CHART.y + CHART.h + 8};
const REST = {x: 352, y: 292};

const Scene: React.FC = () => {
  const T = useTheme();
  const f = useCurrentFrame();

  const dim = ease(f, 38, 46) * (1 - ease(f, 114, 124));
  const toCorner = ease(f, 46, 68);
  const drag = ease(f, 72, 108);
  const home = ease(f, 150, 186);
  const cx = f < 72 ? REST.x + (FROM.x - REST.x) * toCorner : f < 150 ? FROM.x + (TO.x - FROM.x) * drag : TO.x + (REST.x - TO.x) * home;
  const cy = f < 72 ? REST.y + (FROM.y - REST.y) * toCorner : f < 150 ? FROM.y + (TO.y - FROM.y) * drag : TO.y + (REST.y - TO.y) * home;
  const crosshair = f >= 40 && f < 112;
  const dragging = f >= 72 && f < 112;
  const toast = f < 159 ? sp(f, 114) : 1 - ease(f, 159, 167);

  return (
    <>
      <MenuBar app="Analytics" menus={['File', 'Edit', 'View', 'Window']} glow={glowAt(f, 112)} />
      <AppWindow x={40} y={50} w={420} h={252} title="Growth · This week">
        <div style={{position: 'absolute', left: CHART.x - 40, top: CHART.y - 80, borderRadius: 8, overflow: 'hidden', border: `1px solid ${T.divider}`}}>
          <Chart w={CHART.w} h={CHART.h} />
        </div>
        <div style={{position: 'absolute', left: 20, top: 14, fontSize: 13, fontWeight: 600}}>Overview</div>
        <div style={{position: 'absolute', left: 268, top: 44, width: 132}}>
          <StatTile label="Active this week" value="4,812" />
          <StatTile label="Retention" value="38%" />
        </div>
      </AppWindow>

      {dim > 0 && (f < 72 ? (
        <div style={{position: 'absolute', inset: 0, background: T.dim, opacity: dim, zIndex: 55}} />
      ) : (
        <div
          style={{
            position: 'absolute', left: FROM.x, top: FROM.y, width: cx - FROM.x, height: cy - FROM.y, zIndex: 55, opacity: dim,
            boxShadow: `0 0 0 2000px ${T.dim}`, outline: '1px solid rgba(255,255,255,0.85)',
          }}
        />
      ))}
      {dragging && (
        <div style={{position: 'absolute', left: cx + 10, top: cy + 8, zIndex: 81, fontFamily: font.mono, fontSize: 9, color: '#fff', textShadow: '0 0 2px rgba(0,0,0,0.9)', lineHeight: '11px'}}>
          <div>{Math.round((cx - FROM.x) * 2)}</div>
          <div>{Math.round((cy - FROM.y) * 2)}</div>
        </div>
      )}

      <Cursor x={cx} y={cy} kind={crosshair ? 'cross' : 'arrow'} />

      <ToastCard a={toast}>
        <KeptBody
          thumb={<Thumb kind="screenshot" w={44} h={44} radius={7}><div style={{padding: '9px 0', background: T.appWindow}}><Chart w={42} h={24} /></div></Thumb>}
          subtitle="Screenshot"
          progress={Math.min(1, Math.max(0, (f - 114) / 45))}
        />
      </ToastCard>
      <KeyHUD keys={['⌃', '⌥', 'S']} label="Keep" enter={6} exit={48} downs={[16, 20, 24]} ups={[36, 36, 36]} />
    </>
  );
};

export const KeepRegion: React.FC<ClipProps> = ({theme}) => (
  <Stage theme={theme}>
    <Scene />
  </Stage>
);
