import * as stylex from '@stylexjs/stylex';
import { colors, fonts, sizes, space, rules, measure, bp } from '../tokens.stylex';

export const base = stylex.create({
  html: {
    backgroundColor: colors.paper,
    color: colors.ink,
    fontFamily: fonts.sans,
    fontSize: '100%',
    fontVariantNumeric: 'lining-nums tabular-nums',
    WebkitFontSmoothing: 'antialiased',
    textRendering: 'optimizeLegibility',
    colorScheme: 'light',
  },
  body: {
    fontSize: sizes.body,
    lineHeight: 1.6,
    minHeight: '100vh',
  },
  page: {
    maxWidth: measure.page,
    marginInline: 'auto',
    paddingInline: { default: space.s7, [bp.narrow]: space.s4 },
  },
});

export const type = stylex.create({
  h1: {
    fontFamily: fonts.display,
    fontStretch: '112.5%',
    fontWeight: 650,
    fontSize: { default: sizes.h1, [bp.narrow]: sizes.h2 },
    lineHeight: 1.08,
    letterSpacing: '-0.015em',
    textWrap: 'balance',
  },
  h2: {
    fontFamily: fonts.display,
    fontStretch: '112.5%',
    fontWeight: 650,
    fontSize: { default: sizes.h2, [bp.narrow]: sizes.h3 },
    lineHeight: 1.15,
    letterSpacing: '-0.01em',
    paddingBottom: space.s3,
    borderBottomWidth: rules.heavy,
    borderBottomStyle: 'solid',
    borderBottomColor: colors.ink,
    marginTop: space.s8,
    marginBottom: space.s5,
    maxWidth: measure.text,
    textWrap: 'balance',
  },
  h3: {
    fontFamily: fonts.display,
    fontStretch: '112.5%',
    fontWeight: 600,
    fontSize: sizes.h3,
    lineHeight: 1.25,
    marginTop: space.s7,
    marginBottom: space.s3,
    maxWidth: measure.text,
  },
  num: {
    fontFamily: fonts.mono,
    fontWeight: 500,
    fontSize: '0.62em',
    letterSpacing: '0.02em',
    color: colors.ink2,
    marginRight: '0.6em',
    verticalAlign: '0.22em',
  },
  p: {
    maxWidth: measure.text,
    marginBottom: '1em',
    textWrap: 'pretty',
    hangingPunctuation: 'first',
  },
  lede: {
    maxWidth: measure.text,
    fontSize: sizes.h3,
    lineHeight: 1.45,
    marginBottom: space.s6,
    textWrap: 'pretty',
  },
  label: {
    fontFamily: fonts.mono,
    fontSize: sizes.label,
    fontWeight: 500,
    lineHeight: 1.4,
    letterSpacing: '0.08em',
    textTransform: 'uppercase',
    color: colors.ink2,
  },
  labelInk: { color: colors.ink },
  labelSignal: { color: colors.signal },
  mono: { fontFamily: fonts.mono },
  small: { fontSize: sizes.small, lineHeight: 1.55 },
  muted: { color: colors.ink2 },
  code: {
    fontFamily: fonts.mono,
    fontSize: '0.86em',
    backgroundColor: colors.panel,
    paddingInline: '0.28em',
    paddingBlock: '0.06em',
  },
  a: {
    color: 'inherit',
    textDecorationLine: 'underline',
    textDecorationThickness: rules.hair,
    textUnderlineOffset: '0.2em',
    textDecorationColor: { default: colors.rule, ':hover': colors.ink },
  },
  list: {
    maxWidth: measure.text,
    paddingLeft: '1.2em',
    marginBottom: '1em',
  },
});

export const rule = stylex.create({
  base: { borderWidth: 0, borderTopStyle: 'solid', marginBlock: space.s6 },
  hair: { borderTopWidth: rules.hair, borderTopColor: colors.rule },
  heavy: { borderTopWidth: rules.heavy, borderTopColor: colors.ink },
});

export const layout = stylex.create({
  // The article is the text column. Margin notes and gatefolds extend past it to the right.
  article: { paddingBlock: space.s7, position: 'relative', maxWidth: measure.text },
  // Margin column on wide screens: content floats right into the gutter beside the text column.
  aside: {
    float: { default: 'none', [bp.wide]: 'right' },
    clear: 'right',
    width: { default: 'auto', [bp.wide]: measure.margin },
    marginRight: { default: 0, [bp.wide]: `calc(-1 * (${measure.margin} + ${measure.gutter}))` },
    marginTop: { default: space.s4, [bp.wide]: space.s1 },
    marginBottom: space.s4,
    paddingLeft: { default: space.s3, [bp.wide]: 0 },
    borderLeftWidth: { default: rules.hair, [bp.wide]: 0 },
    borderLeftStyle: 'solid',
    borderLeftColor: colors.rule,
    fontSize: sizes.small,
    lineHeight: 1.5,
    color: colors.ink2,
  },
  // Wide content stays inside the text column + margin ("gatefold" on wide screens).
  wide: {
    width: { default: 'auto', [bp.wide]: `calc(${measure.text} + ${measure.gutter} + ${measure.margin})` },
  },
  measure: { maxWidth: measure.text },
  clear: { clear: 'both' },
  stack: { display: 'flex', flexDirection: 'column' },
  row: { display: 'flex', flexWrap: 'wrap', alignItems: 'baseline' },
});

export const frame = stylex.create({
  figure: {
    position: 'relative',
    marginTop: space.s7,
    marginBottom: space.s6,
    paddingTop: space.s4,
    paddingInline: space.s4,
    paddingBottom: space.s4,
    borderWidth: rules.hair,
    borderStyle: 'solid',
    borderColor: colors.ink,
  },
  panel: { backgroundColor: colors.panel },
  tab: {
    position: 'absolute',
    top: 0,
    left: `calc(-1 * ${rules.hair})`,
    transform: 'translateY(-100%)',
    paddingInline: space.s2,
    paddingBlock: '0.2em',
    backgroundColor: colors.ink,
    color: colors.paper,
    whiteSpace: 'nowrap',
  },
  tabRight: {
    position: 'absolute',
    top: 0,
    right: 0,
    transform: 'translateY(-100%)',
    paddingBlock: '0.2em',
    whiteSpace: 'nowrap',
  },
  caption: {
    marginTop: space.s3,
    fontSize: sizes.small,
    lineHeight: 1.5,
    color: colors.ink2,
  },
  scroll: { overflowX: 'auto' },
});
