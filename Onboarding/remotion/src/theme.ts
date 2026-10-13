// Tokens copied from Sources/DaemonUI/Theme.swift (Ivory = light, Smoked = dark).
// The desktop and third-party window colors are only for these clips.
export type Theme = {
  canvasTop: string;
  canvasBottom: string;
  menuBar: string;
  panelTop: string;
  panelBottom: string;
  selectedRow: string;
  divider: string;
  border: string;
  well: string;
  kbd: string;
  kbdBorder: string;
  text: string;
  text2: string;
  text3: string;
  accent: string;
  accentRGB: string; // "r,g,b" for rgba()
  onAccent: string;
  selAlpha: number; // text selection / paste flash tint of the accent
  thumbDark: string;
  thumbLight: string;
  thumbLine: string;
  appWindow: string;
  appTitlebar: string;
  appBorder: string;
  dim: string;
  shadow: string;
};

export const ivory: Theme = {
  canvasTop: '#F3EEE4',
  canvasBottom: '#E6DED1',
  menuBar: 'rgba(246,241,232,0.82)',
  panelTop: '#F6F0E2',
  panelBottom: '#F2EBDE',
  selectedRow: '#ECDED4',
  divider: '#E1DACE',
  border: '#E3DACB',
  well: '#E9E0D4',
  kbd: '#EDE5D9',
  kbdBorder: '#D5CBBD',
  text: '#1E1A17',
  text2: '#6B625A',
  text3: '#8E857B',
  accent: '#7A1F2B',
  accentRGB: '122,31,43',
  onAccent: '#FBF5EC',
  selAlpha: 0.2,
  thumbDark: '#1D1F25',
  thumbLight: '#F5F1EA',
  thumbLine: '#5A5D66',
  appWindow: '#FBF8F3',
  appTitlebar: '#F2ECE2',
  appBorder: '#DCD3C5',
  dim: 'rgba(30,26,23,0.32)',
  shadow: 'rgba(60,40,20,0.16)',
};

export const smoked: Theme = {
  canvasTop: '#232A33',
  canvasBottom: '#171B21',
  menuBar: 'rgba(32,38,47,0.85)',
  panelTop: '#27313D',
  panelBottom: '#1E242D',
  selectedRow: '#39424F',
  divider: '#3A4350',
  border: '#3A4350',
  well: '#2E353F',
  kbd: '#2F3741',
  kbdBorder: '#4A5361',
  text: '#E8E7E5',
  text2: '#A3A6AD',
  text3: '#7C828C',
  accent: '#7FB8E8',
  accentRGB: '127,184,232',
  onAccent: '#12202E',
  selAlpha: 0.32,
  thumbDark: '#1D1F25',
  thumbLight: '#F3F1EC',
  thumbLine: '#5A5D66',
  appWindow: '#262C34',
  appTitlebar: '#2D343D',
  appBorder: '#3D4652',
  dim: 'rgba(5,8,12,0.45)',
  shadow: 'rgba(0,0,0,0.38)',
};

export const themes = {ivory, smoked};
export type ThemeName = keyof typeof themes;

export const font = {
  ui: '-apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif',
  serif: 'ui-serif, "New York", Georgia, serif',
  mono: 'ui-monospace, "SF Mono", Menlo, monospace',
};
