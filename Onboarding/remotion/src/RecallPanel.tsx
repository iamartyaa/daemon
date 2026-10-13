import React from 'react';
import {Kbd, KeyHint, Kind, Mark, rgba, Thumb, useTheme} from './ui';

// The Recall panel from Sources/DaemonUI/RecallView.swift at its real 720 × 480 point size;
// clips place it with `zoom` so the proportions stay exact.
export const PANEL = {w: 720, h: 480};

export type Hit = {
  kind: Kind; title: string; source: string; when: string; badge?: string;
  preview?: React.ReactNode; text?: string; note?: string; openIn?: string;
};

const RECENT: Hit[] = [
  {kind: 'screenshot', title: 'Pricing — Monthly / Yearly toggle, dark', source: 'Figma', when: '2 min ago'},
  {kind: 'text', title: 'Flight confirmation, LHR → SFO', source: 'Mail', when: '1 hr ago'},
  {kind: 'link', title: 'DMN-214 Recall loses focus on paste', source: 'Safari', when: 'Today'},
  {kind: 'voice', title: '“Call Hana about the Tuesday review”', source: 'Voice', when: '0:12 · Today'},
  {kind: 'pdf', title: 'Q3 roadmap.pdf', source: 'Preview', when: 'Yesterday'},
  {kind: 'screenshot', title: 'Onboarding flow sketch', source: 'Freeform', when: 'Yesterday'},
];

const Divider: React.FC<{vertical?: boolean}> = ({vertical}) => {
  const T = useTheme();
  return <div style={vertical ? {width: 1, alignSelf: 'stretch', background: T.divider} : {height: 1, background: T.divider}} />;
};

const FooterHint: React.FC<{k: string; label: string; lit?: number}> = ({k, label, lit}) => {
  const T = useTheme();
  return (
    <div style={{display: 'flex', alignItems: 'center', gap: 6}}>
      <Kbd label={k} fontSize={14} lit={lit} />
      <span style={{fontSize: 11.5, color: T.text2}}>{label}</span>
    </div>
  );
};

const ResultRow: React.FC<{hit: Hit; selected: boolean}> = ({hit, selected}) => {
  const T = useTheme();
  return (
    <div style={{display: 'flex', alignItems: 'center', gap: 14, height: 46, padding: '0 10px', borderRadius: 8, background: selected ? T.selectedRow : 'transparent'}}>
      <Thumb kind={hit.kind} w={52} h={34} />
      <div style={{display: 'flex', flexDirection: 'column', gap: 2, flex: 1, minWidth: 0}}>
        <span style={{fontSize: 13, color: T.text, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis'}}>{hit.title}</span>
        <span style={{fontSize: 11.5, color: T.text2, whiteSpace: 'nowrap'}}>{hit.source} · {hit.when}</span>
      </div>
      {hit.badge && (
        <span style={{fontSize: 11.5, color: T.text2, padding: '0 7px', height: 20, lineHeight: '18px', boxSizing: 'border-box', background: T.well, border: `1px solid ${T.kbdBorder}`, borderRadius: 4, flexShrink: 0}}>
          {hit.badge}
        </span>
      )}
    </div>
  );
};

const Preview: React.FC<{hit: Hit; pasteInto: string; enterLit: number}> = ({hit, pasteInto, enterLit}) => {
  const T = useTheme();
  const action = (title: string, key: string, primary: boolean, lit = 0) => (
    <div style={{display: 'flex', alignItems: 'center', justifyContent: 'space-between'}}>
      <span style={{fontSize: 13, color: primary ? T.text : T.text2}}>{title}</span>
      <Kbd label={key} fontSize={11} lit={lit} />
    </div>
  );
  return (
    <div style={{flex: 1, display: 'flex', flexDirection: 'column', padding: '12px 20px', minWidth: 0}}>
      {hit.kind === 'text' && hit.text ? (
        <div style={{minHeight: 140, boxSizing: 'border-box', padding: 14, borderRadius: 8, background: T.well, fontSize: 13, lineHeight: '18px', color: T.text}}>{hit.text}</div>
      ) : (
        hit.preview ?? <Thumb kind={hit.kind} w={295} h={140} radius={8} />
      )}
      <div style={{fontSize: 15, fontWeight: 600, color: T.text, marginTop: 14}}>{hit.title}</div>
      <div style={{fontSize: 11.5, color: T.text2, marginTop: 4}}>{hit.source} · kept {hit.when.toLowerCase()}</div>
      {hit.note && (
        <div style={{marginTop: 10, padding: '9px 12px', borderRadius: 8, background: T.well, border: `1px solid ${T.border}`, fontSize: 13, fontStyle: 'italic', color: T.text2, lineHeight: '17px'}}>
          “{hit.note}”
        </div>
      )}
      <div style={{flex: 1, minHeight: 8}} />
      {action(`Paste into ${pasteInto}`, '↵', true, enterLit)}
      {hit.openIn && <div style={{marginTop: 8}}>{action(`Open in ${hit.openIn}`, '⌘↵', false)}</div>}
    </div>
  );
};

const RecentGrid: React.FC = () => {
  const T = useTheme();
  return (
    <div style={{flex: 1, padding: '14px 20px 0'}}>
      <div style={{display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10}}>
        <span style={{fontFamily: 'ui-monospace, monospace', fontSize: 11, fontWeight: 500, letterSpacing: 1, color: T.text2}}>RECENT</span>
        <KeyHint k="⌘R" label="Show all" />
      </div>
      <div style={{display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', columnGap: 12, rowGap: 14}}>
        {RECENT.map((hit) => (
          <div key={hit.title} style={{minWidth: 0}}>
            <Thumb kind={hit.kind} w={218} h={104} />
            <div style={{fontSize: 13, color: T.text, marginTop: 9, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis'}}>{hit.title}</div>
            <div style={{display: 'flex', justifyContent: 'space-between', fontSize: 11.5, color: T.text2, marginTop: 2}}>
              <span>{hit.source}</span>
              <span>{hit.when}</span>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
};

export type PanelProps = {
  query: React.ReactNode; // already-rendered query text, or null for the placeholder
  caret: boolean;
  recent: number; // 1 = recent grid, 0 = results (cross-fades in between)
  hits: Hit[];
  rowIn: (i: number) => number; // 0…1 appearance of each result row
  rowY?: (i: number) => number; // row slot (fractional while rows move); defaults to i
  previewIn?: number; // defaults to the selected row's appearance
  selection: number;
  chips: [string, number][];
  pasteInto: string;
  enterLit?: number;
};

export const RecallPanel: React.FC<PanelProps> = ({query, caret, recent, hits, rowIn, rowY = (i) => i, previewIn, selection, chips, pasteInto, enterLit = 0}) => {
  const pv = previewIn ?? rowIn(selection);
  const T = useTheme();
  const caretEl = <span style={{display: 'inline-block', width: 1.5, height: 20, background: T.accent, verticalAlign: 'middle', opacity: caret ? 1 : 0, margin: '0 1px'}} />;
  const showResults = recent < 1;
  return (
    <div
      style={{
        width: PANEL.w, height: PANEL.h, borderRadius: 14, overflow: 'hidden', display: 'flex', flexDirection: 'column',
        background: `linear-gradient(${T.panelTop}, ${T.panelBottom})`, border: `1px solid ${T.border}`, boxSizing: 'border-box',
        boxShadow: `0 24px 60px ${T.shadow}, 0 2px 8px ${T.shadow}`,
      }}
    >
      {/* Header */}
      <div style={{height: 58, display: 'flex', alignItems: 'center', gap: 14, padding: '0 20px', flexShrink: 0}}>
        <Mark size={18} color={T.text2} />
        <div style={{flex: 1, fontSize: 16.5, color: T.text, whiteSpace: 'nowrap', display: 'flex', alignItems: 'center'}}>
          {query ? <>{query}{caretEl}</> : <>{caretEl}<span style={{color: T.text3}}>Recall anything…</span></>}
        </div>
        {recent >= 0.5 ? <span style={{fontSize: 11.5, color: T.text2}}>1,284 kept · private to this Mac</span> : <KeyHint k="⇥" label="filters" />}
      </div>
      <Divider />
      <div style={{flex: 1, position: 'relative'}}>
        {recent > 0 && <div style={{position: 'absolute', inset: 0, display: 'flex', opacity: recent}}><RecentGrid /></div>}
        {showResults && (
          <div style={{position: 'absolute', inset: 0, display: 'flex', flexDirection: 'column', opacity: 1 - recent}}>
            {/* Chips */}
            <div style={{height: 40, display: 'flex', alignItems: 'center', gap: 4, padding: '0 16px', flexShrink: 0}}>
              {chips.map(([name, n], i) => (
                <div key={name} style={{display: 'flex', alignItems: 'center', gap: 5, height: 26, padding: '0 12px', borderRadius: 14, boxSizing: 'border-box', background: i === 0 ? T.panelTop : 'transparent', border: `1px solid ${i === 0 ? T.kbdBorder : 'transparent'}`}}>
                  <span style={{fontSize: 12.5, color: T.text}}>{name}</span>
                  <span style={{fontSize: 11, color: T.text2}}>{n}</span>
                </div>
              ))}
            </div>
            <Divider />
            <div style={{flex: 1, display: 'flex', minHeight: 0}}>
              <div style={{width: 384, position: 'relative', flexShrink: 0}}>
                {hits.map((hit, i) => {
                  const a = rowIn(i);
                  if (a <= 0) return null;
                  return (
                    <div key={hit.title} style={{position: 'absolute', left: 10, right: 10, top: 8 + rowY(i) * 46, opacity: a, transform: `translateY(${(1 - a) * 5}px)`}}>
                      <ResultRow hit={hit} selected={i === selection} />
                    </div>
                  );
                })}
              </div>
              <Divider vertical />
              {hits[selection] && pv > 0 && (
                <div style={{flex: 1, display: 'flex', minWidth: 0, opacity: pv}}>
                  <Preview hit={hits[selection]} pasteInto={pasteInto} enterLit={enterLit} />
                </div>
              )}
            </div>
          </div>
        )}
      </div>
      <Divider />
      {/* Footer */}
      <div style={{height: 40, display: 'flex', alignItems: 'center', gap: 18, padding: '0 16px', flexShrink: 0}}>
        {recent >= 0.5 && <FooterHint k="↑↓" label="Browse" />}
        <FooterHint k="↵" label="Paste" lit={enterLit} />
        {recent < 0.5 && <FooterHint k="⌘C" label="Copy" />}
        <FooterHint k="Space" label="Preview" />
        {recent < 0.5 && <FooterHint k="⌘↵" label="Open" />}
        <div style={{flex: 1}} />
        <FooterHint k="Esc" label="Close" />
      </div>
    </div>
  );
};

/** The rich "PLANS" preview from the design screenshot. */
export const PlansPreview: React.FC = () => {
  const T = useTheme();
  const card = (name: string, price: string, pro: boolean) => (
    <div style={{flex: 1, height: 74, borderRadius: 6, border: `1px solid ${pro ? T.accent : '#3A3D45'}`, padding: '10px 11px', boxSizing: 'border-box', position: 'relative'}}>
      {pro && <span style={{position: 'absolute', right: 6, top: -7, fontSize: 8, fontWeight: 600, padding: '1px 5px', borderRadius: 6, background: T.accent, color: T.onAccent}}>−20%</span>}
      <div style={{fontSize: 8.5, color: '#9A9DA4'}}>{name}</div>
      <div style={{fontSize: 15, fontWeight: 600, color: '#F2F2F0', marginTop: 4}}>{price}<span style={{fontSize: 8.5, fontWeight: 400, color: '#9A9DA4'}}>/mo</span></div>
    </div>
  );
  return (
    <div style={{height: 140, borderRadius: 8, background: T.thumbDark, border: `1px solid ${T.border}`, padding: '14px 16px', boxSizing: 'border-box'}}>
      <div style={{display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 12}}>
        <span style={{fontSize: 8.5, letterSpacing: 1, fontWeight: 600, color: '#C9CAD0'}}>PLANS</span>
        <div style={{display: 'flex', borderRadius: 10, background: '#2C2F37', padding: 2, fontSize: 8, color: '#C9CAD0'}}>
          <span style={{padding: '2px 8px'}}>Monthly</span>
          <span style={{padding: '2px 8px', borderRadius: 8, background: T.accent, color: T.onAccent, fontWeight: 600}}>Yearly</span>
        </div>
      </div>
      <div style={{display: 'flex', gap: 8}}>
        {card('Starter', '$8', false)}
        {card('Pro', '$12', true)}
      </div>
    </div>
  );
};

/** Query text where `tokens` ranges render as subtle filter tokens (`a` 0…1 each). */
export const TokenQuery: React.FC<{text: string; tokens: {from: number; to: number; a: number}[]}> = ({text, tokens}) => {
  const T = useTheme();
  const parts: React.ReactNode[] = [];
  let at = 0;
  for (const tk of tokens) {
    if (tk.from >= text.length) break;
    if (tk.from > at) parts.push(<span key={`p${at}`} style={{whiteSpace: 'pre'}}>{text.slice(at, tk.from)}</span>);
    const word = text.slice(tk.from, Math.min(tk.to, text.length));
    parts.push(
      <span
        key={`t${tk.from}`}
        style={{
          whiteSpace: 'pre', borderRadius: 6, padding: '1px 0', margin: `0 ${2 * tk.a}px`,
          background: rgba(T.accentRGB, 0.1 * tk.a), boxShadow: `inset 0 0 0 1px ${rgba(T.accentRGB, 0.28 * tk.a)}`,
          paddingLeft: 6 * tk.a, paddingRight: 6 * tk.a,
        }}
      >
        {word}
      </span>,
    );
    at = Math.min(tk.to, text.length);
  }
  if (at < text.length) parts.push(<span key={`p${at}`} style={{whiteSpace: 'pre'}}>{text.slice(at)}</span>);
  return <>{parts}</>;
};
