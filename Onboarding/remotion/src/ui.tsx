import React, {createContext, useContext} from 'react';
import {AbsoluteFill, Easing, interpolate, interpolateColors, random, spring, useCurrentFrame} from 'remotion';
import {font, Theme, ThemeName, themes} from './theme';

// Everything is authored in points on a 560 × 360 stage and drawn at 2× (the clips are 1120 × 720).
export const W = 560;
export const H = 360;
export const FPS = 30;

const ThemeCtx = createContext<Theme>(themes.ivory);
export const useTheme = () => useContext(ThemeCtx);
export type ClipProps = {theme: ThemeName};

const clamp = {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'} as const;
const calm = Easing.bezier(0.25, 0.1, 0.25, 1);

/** Eased 0→1 (or from→to) between frames a and b. */
export const ease = (f: number, a: number, b: number, from = 0, to = 1) =>
  interpolate(f, [a, b], [from, to], {...clamp, easing: calm});

/** Critically damped spring (< 0.2 % overshoot) starting at `start`. */
export const sp = (f: number, start: number, stiffness = 200) =>
  spring({frame: f - start, fps: FPS, config: {damping: 2 * Math.sqrt(stiffness) * 0.92, stiffness, mass: 1}});

/** Key press amount: lights in 2 frames at `down`, goes dark over 5 frames at `up`. */
export const press = (f: number, down: number, up: number) =>
  f < up ? interpolate(f, [down - 1, down + 1], [0, 1], clamp) : interpolate(f, [up, up + 5], [1, 0], clamp);

/** Menu bar mark glow after a keep: up in 3 frames, fades over 1.2 s. */
export const glowAt = (f: number, start: number) =>
  f < start + 3 ? interpolate(f, [start, start + 3], [0, 1], clamp) : ease(f, start + 3, start + 3 + 1.2 * FPS, 1, 0);

/** Frame at which each character of `text` appears, at a natural, slightly uneven pace. */
export const typeTimes = (text: string, start: number, perChar: number) => {
  const times: number[] = [];
  let at = start;
  for (let i = 0; i < text.length; i++) {
    at += perChar * (0.7 + 0.6 * random(`type-${text}-${i}`)) + (text[i - 1] === ' ' ? perChar * 0.8 : 0);
    times.push(Math.round(at));
  }
  return times;
};
export const typedCount = (times: number[], f: number) => times.filter((t) => t <= f).length;

export const rgba = (rgb: string, a: number) => `rgba(${rgb},${a})`;

// MARK: - Stage, desktop, menu bar

export const Stage: React.FC<{theme: ThemeName; children: React.ReactNode}> = ({theme, children}) => {
  const T = themes[theme];
  return (
    <ThemeCtx.Provider value={T}>
      <AbsoluteFill style={{background: T.canvasBottom}}>
        <div
          style={{
            position: 'absolute', left: 0, top: 0, width: W, height: H, zoom: 2, overflow: 'hidden',
            fontFamily: font.ui, color: T.text, WebkitFontSmoothing: 'antialiased',
            background: `radial-gradient(120% 90% at 8% 0%, ${T.canvasTop} 0%, transparent 60%), linear-gradient(165deg, ${T.canvasTop}, ${T.canvasBottom})`,
          }}
        >
          {children}
        </div>
      </AbsoluteFill>
    </ThemeCtx.Provider>
  );
};

export const MenuBar: React.FC<{app: string; menus?: string[]; glow?: number}> = ({app, menus = ['File', 'Edit', 'View'], glow = 0}) => {
  const T = useTheme();
  return (
    <div
      style={{
        position: 'absolute', left: 0, top: 0, right: 0, height: 22, display: 'flex', alignItems: 'center',
        padding: '0 12px', gap: 14, fontSize: 12, background: T.menuBar, color: T.text, zIndex: 50,
        borderBottom: `0.5px solid ${rgba('0,0,0', 0.06)}`,
      }}
    >
      <span style={{fontWeight: 700}}>{app}</span>
      {menus.map((m) => <span key={m}>{m}</span>)}
      <div style={{flex: 1}} />
      <Mark size={13} color={interpolateColors(glow, [0, 1], [T.text, T.accent])} halo={glow} strong />
      <Battery />
      <span>Mon 12 Oct</span>
      <span>9:41</span>
    </div>
  );
};

const Battery = () => {
  const T = useTheme();
  return (
    <div style={{display: 'flex', alignItems: 'center', gap: 1}}>
      <div style={{width: 19, height: 9, borderRadius: 2.5, border: `1px solid ${T.text}`, padding: 1.2, boxSizing: 'border-box', opacity: 0.85}}>
        <div style={{width: '72%', height: '100%', borderRadius: 1, background: T.text}} />
      </div>
      <div style={{width: 1.5, height: 3.5, borderRadius: 1, background: T.text, opacity: 0.6}} />
    </div>
  );
};

/** The Daemon mark: a dot inside a ring. `halo` 0…1 adds the accent glow. */
export const Mark: React.FC<{size: number; color: string; halo?: number; strong?: boolean}> = ({size, color, halo = 0, strong}) => {
  const T = useTheme();
  return (
    <div style={{position: 'relative', width: size, height: size, flexShrink: 0}}>
      {halo > 0 && (
        <div
          style={{
            position: 'absolute', inset: 0, borderRadius: '50%', background: rgba(T.accentRGB, 0.12 * halo),
            boxShadow: `0 0 ${strong ? size * 0.7 : size / 5}px ${rgba(T.accentRGB, (strong ? 0.75 : 0.35) * halo)}`,
          }}
        />
      )}
      <div style={{position: 'absolute', inset: 0, borderRadius: '50%', border: `${Math.max(1.3, size / 12)}px solid ${color}`}} />
      <div
        style={{
          position: 'absolute', left: size * 0.35, top: size * 0.35, width: size * 0.3, height: size * 0.3,
          borderRadius: '50%', background: color,
        }}
      />
    </div>
  );
};

// MARK: - Key caps

export const Kbd: React.FC<{
  label: string; fontSize?: number; minW?: number; minH?: number; radius?: number; pad?: number; lit?: number;
}> = ({label, fontSize = 11.5, minW = 22, minH = 18, radius = 4, pad = 6, lit = 0}) => {
  const T = useTheme();
  return (
    <div
      style={{
        display: 'inline-flex', alignItems: 'center', justifyContent: 'center', boxSizing: 'border-box',
        minWidth: minW, height: minH, padding: `0 ${pad}px`, borderRadius: radius, fontSize, lineHeight: 1,
        background: interpolateColors(lit, [0, 1], [T.kbd, T.accent]),
        border: `1px solid ${interpolateColors(lit, [0, 1], [T.kbdBorder, T.accent])}`,
        color: interpolateColors(lit, [0, 1], [T.text2, T.onAccent]),
        transform: `translateY(${lit}px)`,
        boxShadow: lit > 0 ? `0 0 ${10 * lit}px ${rgba(T.accentRGB, 0.45 * lit)}` : 'none',
        flexShrink: 0,
      }}
    >
      {label}
    </div>
  );
};

export const KeyHint: React.FC<{k: string; label: string; lit?: number}> = ({k, label, lit}) => {
  const T = useTheme();
  return (
    <div style={{display: 'flex', alignItems: 'center', gap: 6}}>
      <Kbd label={k} lit={lit} />
      <span style={{fontSize: 11.5, color: T.text2}}>{label}</span>
    </div>
  );
};

/** On-screen key caps at the bottom of the stage, so a first-time user sees what is pressed. */
export const KeyHUD: React.FC<{
  keys: string[]; label?: string; enter: number; exit: number; downs: number[]; ups: number[]; extra?: React.ReactNode;
  compact?: boolean; // smaller caps, for clips where the Recall panel fills the stage
}> = ({keys, label, enter, exit, downs, ups, extra, compact}) => {
  const T = useTheme();
  const f = useCurrentFrame();
  const a = ease(f, enter, enter + 9) * (1 - ease(f, exit, exit + 10));
  if (a <= 0) return null;
  return (
    <div style={{position: 'absolute', left: 0, right: 0, bottom: compact ? 7 : 12, display: 'flex', justifyContent: 'center', zIndex: 60, opacity: a, transform: `translateY(${(1 - a) * 6}px)`}}>
      <div
        style={{
          display: 'flex', alignItems: 'center', gap: 5, padding: label || extra ? (compact ? '4px 10px 4px 4px' : '6px 12px 6px 6px') : compact ? 4 : 6, borderRadius: compact ? 9 : 11,
          background: `linear-gradient(${T.panelTop}, ${T.panelBottom})`, border: `1px solid ${T.border}`,
          boxShadow: `0 6px 18px ${T.shadow}`,
        }}
      >
        {keys.map((k, i) => (
          <Kbd key={i} label={k} fontSize={compact ? 13.5 : 15} minW={compact ? 26 : 30} minH={compact ? 24 : 28} radius={6} pad={compact ? 8 : 9} lit={press(f, downs[i], ups[i])} />
        ))}
        {label && <span style={{marginLeft: 7, fontSize: 13, fontWeight: 600, color: T.text}}>{label}</span>}
        {extra}
      </div>
    </div>
  );
};

// MARK: - Cursor

export const Cursor: React.FC<{x: number; y: number; kind?: 'arrow' | 'ibeam' | 'cross'; opacity?: number}> = ({x, y, kind = 'arrow', opacity = 1}) => {
  if (opacity <= 0) return null;
  const common = {position: 'absolute' as const, zIndex: 80, opacity, filter: 'drop-shadow(0 1px 1.5px rgba(0,0,0,0.35))'};
  if (kind === 'arrow') {
    return (
      <svg width={15} height={22} viewBox="-1 -1 15 22" style={{...common, left: x - 1, top: y - 1}}>
        <path d="M0 0 L0 16.5 L3.9 12.8 L6.6 19 L9.2 17.9 L6.6 11.8 L11.8 11.8 Z" fill="#000" stroke="#fff" strokeWidth={1.2} strokeLinejoin="round" />
      </svg>
    );
  }
  if (kind === 'ibeam') {
    const d = 'M2 0.5 Q4.5 0.5 5 2.5 Q5.5 0.5 8 0.5 M5 2.5 L5 15.5 M2 17.5 Q4.5 17.5 5 15.5 Q5.5 17.5 8 17.5 M3.2 9 L6.8 9';
    return (
      <svg width={10} height={18} viewBox="0 0 10 18" style={{...common, left: x - 5, top: y - 9}}>
        <path d={d} fill="none" stroke="#fff" strokeWidth={3} strokeLinecap="round" />
        <path d={d} fill="none" stroke="#000" strokeWidth={1.2} strokeLinecap="round" />
      </svg>
    );
  }
  const d = 'M10 0 L10 7.5 M10 12.5 L10 20 M0 10 L7.5 10 M12.5 10 L20 10';
  return (
    <svg width={20} height={20} viewBox="0 0 20 20" style={{...common, left: x - 10, top: y - 10}}>
      <path d={d} stroke="#fff" strokeWidth={2.6} strokeLinecap="round" />
      <path d={d} stroke="#000" strokeWidth={1} strokeLinecap="round" />
    </svg>
  );
};

// MARK: - Windows

export const AppWindow: React.FC<{
  x: number; y: number; w: number; h: number; title?: string; children: React.ReactNode; style?: React.CSSProperties;
}> = ({x, y, w, h, title, children, style}) => {
  const T = useTheme();
  return (
    <div
      style={{
        position: 'absolute', left: x, top: y, width: w, height: h, borderRadius: 10, overflow: 'hidden',
        background: T.appWindow, border: `0.5px solid ${T.appBorder}`, boxSizing: 'border-box',
        boxShadow: `0 12px 32px ${T.shadow}, 0 1px 3px ${T.shadow}`, ...style,
      }}
    >
      <div style={{height: 30, display: 'flex', alignItems: 'center', padding: '0 11px', background: T.appTitlebar, borderBottom: `0.5px solid ${T.appBorder}`, position: 'relative'}}>
        {['#FF5F57', '#FEBC2E', '#28C840'].map((c) => (
          <div key={c} style={{width: 10, height: 10, borderRadius: 5, background: c, marginRight: 7}} />
        ))}
        {title && <div style={{position: 'absolute', left: 0, right: 0, textAlign: 'center', fontSize: 12, fontWeight: 600, color: T.text2}}>{title}</div>}
      </div>
      <div style={{position: 'relative', height: h - 30}}>{children}</div>
    </div>
  );
};

// MARK: - Toasts (Sources/DaemonUI/Toasts.swift)

/** The 320 × 66 toast card, top right under the menu bar. `a` 0…1 is its presence. */
export const ToastCard: React.FC<{a: number; children: React.ReactNode}> = ({a, children}) => {
  const T = useTheme();
  if (a <= 0) return null;
  return (
    <div
      style={{
        position: 'absolute', right: 16, top: 30, width: 320, height: 66, borderRadius: 12, overflow: 'hidden', zIndex: 40,
        background: `linear-gradient(${T.panelTop}, ${T.panelBottom})`, border: `1px solid ${T.border}`, boxSizing: 'border-box',
        boxShadow: `0 4px 12px ${rgba('0,0,0', 0.14)}`, opacity: a, transform: `translateY(${(1 - a) * -8}px)`,
      }}
    >
      {children}
    </div>
  );
};

export const KeptBody: React.FC<{thumb: React.ReactNode; subtitle: string; progress: number}> = ({thumb, subtitle, progress}) => {
  const T = useTheme();
  return (
    <div style={{position: 'absolute', inset: 0, display: 'flex', alignItems: 'center', gap: 12, padding: '0 14px 0 12px'}}>
      <div style={{width: 44, height: 44, flexShrink: 0}}>{thumb}</div>
      <div style={{display: 'flex', flexDirection: 'column', gap: 3, flex: 1, minWidth: 0}}>
        <div style={{display: 'flex', alignItems: 'center', gap: 7}}>
          <div style={{width: 7, height: 7, borderRadius: 4, background: T.accent}} />
          <span style={{fontSize: 14, fontWeight: 600, color: T.text}}>Kept</span>
        </div>
        <span style={{fontSize: 11.5, color: T.text2, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis'}}>{subtitle}</span>
      </div>
      <KeyHint k="⇥" label="add a note" />
      <div style={{position: 'absolute', left: 0, bottom: 0, height: 2, width: 320 * progress, background: rgba(T.accentRGB, 0.7)}} />
    </div>
  );
};

export const ListeningBody: React.FC<{levels: number[]; seconds: number}> = ({levels, seconds}) => {
  const T = useTheme();
  return (
    <div style={{position: 'absolute', inset: 0, display: 'flex', alignItems: 'center', gap: 14, padding: '0 16px'}}>
      <Mark size={18} color={T.accent} halo={1} />
      <div style={{display: 'flex', flexDirection: 'column', gap: 6, flex: 1}}>
        <Waveform levels={levels} color={T.accent} barWidth={2} spacing={3.5} height={24} />
        <span style={{fontSize: 13, whiteSpace: 'nowrap'}}>
          <span style={{color: T.text}}>Listening… </span>
          <span style={{color: T.text2}}>release to keep</span>
        </span>
      </div>
      <div style={{display: 'flex', flexDirection: 'column', alignItems: 'flex-end', gap: 4}}>
        <span style={{fontFamily: font.ui, fontVariantNumeric: 'tabular-nums', fontSize: 12, color: T.text2}}>0:{String(seconds).padStart(2, '0')}</span>
        <span style={{fontSize: 11, color: T.text2}}>⌃⌥S held</span>
      </div>
    </div>
  );
};

export const Waveform: React.FC<{levels: number[]; color: string; barWidth: number; spacing: number; height: number}> = ({levels, color, barWidth, spacing, height}) => (
  <div style={{display: 'flex', alignItems: 'center', gap: spacing, height}}>
    {levels.map((l, i) => (
      <div key={i} style={{width: barWidth, height: Math.max(3, height * l), borderRadius: barWidth, background: color, flexShrink: 0}} />
    ))}
  </div>
);

export const SAMPLE_WAVE = [0.3, 0.55, 0.4, 0.8, 0.5, 0.95, 0.6, 0.35, 0.7, 0.45, 0.9, 0.55, 0.3, 0.75, 0.5, 1.0, 0.6, 0.4, 0.85, 0.5, 0.35, 0.65];

// MARK: - Thumbnails (KindDrawing in Components.swift)

export type Kind = 'screenshot' | 'text' | 'link' | 'pdf' | 'voice' | 'video';

export const Thumb: React.FC<{kind: Kind; w: number; h: number; radius?: number; children?: React.ReactNode}> = ({kind, w, h, radius = 6, children}) => {
  const T = useTheme();
  const s = Math.min(2, w / 52);
  const line = (fr: number, color = '#B9B6B0', height = 1.2) => (
    <div style={{width: w * fr, height: height * s, borderRadius: 9, background: color, flexShrink: 0}} />
  );
  const box: React.CSSProperties = {
    width: w, height: h, borderRadius: radius, overflow: 'hidden', position: 'relative', boxSizing: 'border-box',
    border: `1px solid ${T.border}`, flexShrink: 0,
  };
  if (children) return <div style={box}>{children}</div>;
  switch (kind) {
    case 'voice':
      return (
        <div style={{...box, background: T.well, display: 'flex', alignItems: 'center', justifyContent: 'center'}}>
          <Waveform levels={SAMPLE_WAVE} color={T.text2} barWidth={Math.max(1, s)} spacing={2 * s} height={16 * s} />
        </div>
      );
    case 'video':
      return (
        <div style={{...box, background: T.thumbDark, display: 'flex', alignItems: 'center', justifyContent: 'center'}}>
          <svg width={9 * s} height={10 * s} viewBox="0 0 9 10"><path d="M1 0.8 L8.4 5 L1 9.2 Z" fill="#fff" /></svg>
          <div style={{position: 'absolute', left: 4 * s, bottom: 4 * s, width: w * 0.7, height: s, borderRadius: 9, background: T.accent}} />
        </div>
      );
    case 'screenshot':
      return (
        <div style={{...box, background: T.thumbDark, padding: `${7 * s}px 0 0 ${7 * s}px`, display: 'flex', flexDirection: 'column', gap: 4 * s}}>
          <div style={{position: 'relative', width: 28 * s, height: 6 * s, marginBottom: s}}>
            <div style={{position: 'absolute', inset: 0, borderRadius: 9, background: 'rgba(255,255,255,0.14)'}} />
            <div style={{position: 'absolute', left: 0, top: 0, bottom: 0, width: 13 * s, borderRadius: 9, background: T.accent}} />
          </div>
          {line(0.6, T.thumbLine)}
          {line(0.43, T.thumbLine)}
          {line(0.52, T.thumbLine)}
        </div>
      );
    case 'text':
      return (
        <div style={{...box, background: T.thumbLight, padding: 7 * s, display: 'flex', flexDirection: 'column', gap: 4 * s}}>
          <div style={{display: 'flex', alignItems: 'center', gap: 4 * s}}>
            <div style={{width: 7 * s, height: 7 * s, borderRadius: 9, background: '#CFC8BE'}} />
            {line(0.35, '#8F8A82')}
          </div>
          {line(0.73)}
          {line(0.6)}
          <div style={{flex: 1}} />
          <div style={{width: w * 0.8, height: 7 * s, borderRadius: 9, background: '#E6E0D6', display: 'flex', alignItems: 'center', paddingLeft: 4 * s}}>
            {line(0.4, '#8F8A82')}
          </div>
        </div>
      );
    case 'pdf':
      return (
        <div style={{...box, background: '#fff', padding: `${8 * s}px 0 0 ${9 * s}px`, display: 'flex', flexDirection: 'column', gap: 3.5 * s}}>
          <div style={{marginBottom: s}}>{line(0.36, '#4A4D55', 2)}</div>
          {line(0.8)}
          {line(0.8)}
          {line(0.8)}
          {line(0.5)}
        </div>
      );
    case 'link':
      return (
        <div style={{...box, background: T.thumbLight}}>
          <div style={{height: 7 * s, background: '#E6E0D6', display: 'flex', alignItems: 'center', gap: 2 * s, padding: `0 ${3 * s}px`}}>
            <div style={{width: 2.5 * s, height: 2.5 * s, borderRadius: 9, background: '#C9C4BC'}} />
            <div style={{width: 2.5 * s, height: 2.5 * s, borderRadius: 9, background: '#C9C4BC'}} />
            <div style={{flex: 1, height: 3 * s, borderRadius: 9, background: 'rgba(255,255,255,0.9)', marginLeft: 2 * s}} />
          </div>
          <div style={{padding: `${5 * s}px 0 0 ${7 * s}px`, display: 'flex', flexDirection: 'column', gap: 3.5 * s}}>
            <div style={{marginBottom: s}}>{line(0.5, '#6E6A64', 1.6)}</div>
            {line(0.75)}
            {line(0.62)}
            {line(0.66)}
          </div>
        </div>
      );
  }
};
