// Canonical design tokens for REN-01. This file is the single source of truth.
// tokens.stylex.ts is GENERATED from it by scripts/gen-tokens.ts. Do not edit that file by hand.

export type Mode = 'light' | 'dark';

export const color = {
  paper:  { light: '#F2EDE1', dark: '#1C1A17', use: 'Background. Aged stock, never pure white.' },
  panel:  { light: '#E8E2D3', dark: '#25221E', use: 'Listings, spec blocks, figures.' },
  ink:    { light: '#26231E', dark: '#E4DED0', use: 'Text and diagram strokes. Never #000.' },
  ink2:   { light: '#6A645A', dark: '#9C9586', use: 'Captions, comments, labels.' },
  rule:   { light: '#CFC8B8', dark: '#3B3730', use: 'Hairlines, unlit lamps.' },
  signal: { light: '#9A4D2B', dark: '#C77D55', use: 'The only accent. Faults, lit lamps, current §.' },
} as const;

export const font = {
  display: { stack: "'Archivo Variable', 'Archivo', system-ui, sans-serif", use: 'Chapter and § headings. Set SemiExpanded.' },
  sans:    { stack: "'IBM Plex Sans', system-ui, sans-serif", use: 'Prose.' },
  mono:    { stack: "'IBM Plex Mono', ui-monospace, monospace", use: 'Code, labels, part numbers.' },
} as const;

// Six sizes. Nothing else.
export const size = {
  label:   { px: 11,   use: 'Caps labels: FIG 3-1, LISTING 1-4, REV A' },
  small:   { px: 14.5, use: 'Code, captions, margin notes' },
  body:    { px: 17,   use: 'Prose' },
  h3:      { px: 22,   use: 'Subsection heading' },
  h2:      { px: 30,   use: '§ heading' },
  h1:      { px: 44,   use: 'Chapter title' },
} as const;

// 4px base.
export const space = { s1: 4, s2: 8, s3: 12, s4: 16, s5: 24, s6: 32, s7: 48, s8: 64, s9: 96 } as const;

// Two rule weights.
export const rule = { hair: 1, heavy: 3 } as const;

export const measure = { text: '40rem', margin: '14rem', gutter: '3rem', page: '57rem' } as const;
