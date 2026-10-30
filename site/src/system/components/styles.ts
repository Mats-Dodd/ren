import * as stylex from '@stylexjs/stylex';
import { colors, fonts, sizes, space, rules, bp, measure } from '../tokens.stylex';

export const lamp = stylex.create({
  panel: { display: 'inline-flex', flexWrap: 'wrap', columnGap: space.s4, rowGap: space.s1, alignItems: 'center' },
  item: { display: 'inline-flex', alignItems: 'center', gap: space.s2 },
  dot: {
    width: '0.5625rem',
    height: '0.5625rem',
    borderRadius: '50%',
    borderWidth: rules.hair,
    borderStyle: 'solid',
    flexShrink: 0,
  },
  on: { backgroundColor: colors.signal, borderColor: colors.signal },
  off: { backgroundColor: 'transparent', borderColor: colors.ink2 },
});

export const listing = stylex.create({
  pre: {
    fontFamily: fonts.mono,
    fontSize: sizes.small,
    lineHeight: 1.65,
    overflowX: 'auto',
    tabSize: 2,
  },
  // Lines grow to their content so long code scrolls instead of colliding with the markers.
  line: { display: 'grid', gridTemplateColumns: '2.25rem 1fr 1.5rem', alignItems: 'baseline', minWidth: 'max-content' },
  lineBare: { display: 'block' },
  gutter: { color: colors.ink2, userSelect: 'none', textAlign: 'right', paddingRight: space.s4, fontSize: sizes.label },
  marker: { color: colors.ink, userSelect: 'none', textAlign: 'right' },
  code: { whiteSpace: 'pre' },
  kw: { fontWeight: 600 },
  com: { color: colors.ink2, fontStyle: 'italic' },
  str: {},
  num: {},
  type: { fontWeight: 500 },
  mark: { fontWeight: 600 },
  plain: {},
  prompt: { color: colors.ink2, userSelect: 'none' },
  output: { color: colors.ink2 },
  fault: { color: colors.signal },
  notes: { listStyle: 'none', display: 'flex', flexDirection: 'column', gap: space.s2 },
  note: { display: 'grid', gridTemplateColumns: '1.5rem minmax(0, 1fr)' },
  noteMark: { color: colors.ink },
});

export const spec = stylex.create({
  dl: {
    display: 'grid',
    gridTemplateColumns: { default: '9rem minmax(0, 1fr)', [bp.narrow]: '1fr' },
    columnGap: space.s5,
    rowGap: { default: space.s3, [bp.narrow]: 0 },
    fontSize: sizes.small,
    lineHeight: 1.5,
  },
  dt: { paddingTop: '0.18em' },
  dd: { marginBottom: { default: 0, [bp.narrow]: space.s3 } },
});

export const fault = stylex.create({
  root: {
    marginBlock: space.s6,
    maxWidth: measure.text,
    borderTopWidth: rules.heavy,
    borderTopStyle: 'solid',
    borderTopColor: colors.signal,
    borderBottomWidth: rules.hair,
    borderBottomStyle: 'solid',
    borderBottomColor: colors.rule,
  },
  head: {
    display: 'grid',
    gridTemplateColumns: { default: '7rem minmax(0, 1fr)', [bp.narrow]: '1fr' },
    columnGap: space.s5,
    alignItems: 'baseline',
    paddingBlock: space.s3,
    borderBottomWidth: rules.hair,
    borderBottomStyle: 'solid',
    borderBottomColor: colors.rule,
  },
  row: {
    display: 'grid',
    gridTemplateColumns: { default: '7rem minmax(0, 1fr)', [bp.narrow]: '1fr' },
    columnGap: space.s5,
    paddingBlock: space.s2,
    fontSize: sizes.small,
    lineHeight: 1.5,
    borderBottomWidth: rules.hair,
    borderBottomStyle: 'solid',
    borderBottomColor: { default: colors.rule, ':last-child': 'transparent' },
  },
  k: { paddingTop: '0.18em' },
  message: { fontFamily: fonts.mono, fontSize: sizes.small, lineHeight: 1.5 },
});

export const callout = stylex.create({
  root: {
    maxWidth: measure.text,
    marginBlock: space.s6,
    display: 'grid',
    gridTemplateColumns: { default: '7rem minmax(0, 1fr)', [bp.narrow]: '1fr' },
    columnGap: space.s5,
    rowGap: space.s2,
    paddingTop: space.s3,
    borderTopWidth: rules.hair,
    borderTopStyle: 'solid',
    borderTopColor: colors.ink,
    fontSize: sizes.small,
    lineHeight: 1.6,
  },
  caution: { borderTopWidth: rules.heavy, borderTopColor: colors.signal },
  design: {
    backgroundColor: colors.panel,
    borderTopWidth: 0,
    padding: space.s4,
    paddingTop: space.s4,
  },
  body: { display: 'flex', flexDirection: 'column', gap: space.s2 },
});

export const pinout = stylex.create({
  svg: { width: '100%', minWidth: '32rem', height: 'auto', overflow: 'visible' },
  stroke: { stroke: colors.ink, strokeWidth: 1.25, fill: 'none' },
  hair: { stroke: colors.rule, strokeWidth: 1, fill: 'none' },
  body: { stroke: colors.ink, strokeWidth: 1.5, fill: colors.panel },
  pad: { fill: colors.ink, stroke: 'none' },
  text: { fill: colors.ink, fontFamily: fonts.mono, fontSize: '12.5px' },
  pin: { fill: colors.ink2, fontFamily: fonts.mono, fontSize: '10.5px' },
  name: { fill: colors.ink, fontFamily: fonts.mono, fontSize: '15px', fontWeight: 600 },
  sub: { fill: colors.ink2, fontFamily: fonts.mono, fontSize: '11px', letterSpacing: '0.06em' },
  bang: { fill: colors.signal, fontWeight: 600 },
  lampOn: { fill: colors.signal, stroke: colors.signal, strokeWidth: 1 },
  lampOff: { fill: 'none', stroke: colors.ink2, strokeWidth: 1 },
  lampLabel: { fill: colors.ink2, fontFamily: fonts.mono, fontSize: '10.5px', letterSpacing: '0.08em' },
});

export const memmap = stylex.create({
  root: { display: 'flex', flexDirection: 'column', gap: space.s3, minWidth: '34rem' },
  ruler: { position: 'relative', height: '1.6rem', marginLeft: '6rem', borderBottomWidth: rules.hair, borderBottomStyle: 'solid', borderBottomColor: colors.ink },
  tick: { position: 'absolute', bottom: 0, height: '0.4rem', borderLeftWidth: rules.hair, borderLeftStyle: 'solid', borderLeftColor: colors.ink },
  tickLabel: { position: 'absolute', bottom: '0.55rem', transform: 'translateX(-50%)' },
  tickLabelEnd: { transform: 'translateX(-100%)' },
  row: { display: 'grid', gridTemplateColumns: '6rem minmax(0, 1fr)', alignItems: 'stretch' },
  rowLabel: { alignSelf: 'center', paddingRight: space.s3 },
  line: {
    display: 'grid',
    gridTemplateColumns: 'repeat(64, minmax(0, 1fr))',
    borderWidth: rules.hair,
    borderStyle: 'solid',
    borderColor: colors.ink,
    height: '2.75rem',
  },
  cell: {
    borderRightWidth: rules.hair,
    borderRightStyle: 'solid',
    borderRightColor: colors.ink,
    paddingInline: space.s1,
    paddingTop: '0.2rem',
    overflow: 'hidden',
    fontFamily: fonts.mono,
    fontSize: sizes.label,
    lineHeight: 1.3,
    whiteSpace: 'nowrap',
  },
  last: { borderRightWidth: 0 },
  data: { backgroundColor: colors.paper },
  hot: { backgroundColor: colors.panel, boxShadow: `inset 0 ${rules.heavy} 0 ${colors.ink}` },
  pad: {
    backgroundImage: `repeating-linear-gradient(135deg, ${colors.rule} 0 1px, transparent 1px 6px)`,
    color: colors.ink2,
  },
  bytes: { display: 'block', color: colors.ink2 },
});

export const timing = stylex.create({
  svg: { width: '100%', minWidth: '34rem', height: 'auto', overflow: 'visible' },
  lane: { stroke: colors.rule, strokeWidth: 1 },
  axis: { stroke: colors.ink, strokeWidth: 1 },
  msg: { stroke: colors.ink, strokeWidth: 1.1, fill: 'none' },
  head: { fill: colors.ink },
  dot: { fill: colors.ink },
  fault: { stroke: colors.signal, strokeWidth: 2 },
  laneLabel: { fill: colors.ink, fontFamily: fonts.mono, fontSize: '11.5px', letterSpacing: '0.06em' },
  tickLabel: { fill: colors.ink2, fontFamily: fonts.mono, fontSize: '10.5px' },
  evLabel: { fill: colors.ink2, fontFamily: fonts.mono, fontSize: '10.5px' },
  faultLabel: { fill: colors.signal, fontFamily: fonts.mono, fontSize: '10.5px', fontWeight: 600, letterSpacing: '0.06em' },
});
