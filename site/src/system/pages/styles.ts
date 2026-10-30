import * as stylex from '@stylexjs/stylex';
import { colors, fonts, sizes, space, rules, bp, measure } from '../tokens.stylex';

export const cover = stylex.create({
  root: { paddingTop: { default: space.s9, [bp.narrow]: space.s7 }, maxWidth: measure.text },
  id: {
    fontFamily: fonts.display,
    fontStretch: '125%',
    fontWeight: 700,
    fontSize: sizes.h1,
    lineHeight: 1,
    letterSpacing: '-0.01em',
    marginBottom: space.s3,
  },
  meta: { display: 'flex', flexWrap: 'wrap', gap: space.s4, marginTop: space.s5, marginBottom: space.s8 },
  toc: { listStyle: 'none', borderTopWidth: rules.heavy, borderTopStyle: 'solid', borderTopColor: colors.ink },
  entry: {
    display: 'grid',
    gridTemplateColumns: '3.5rem minmax(0, 1fr) auto',
    columnGap: space.s3,
    alignItems: 'baseline',
    paddingBlock: space.s3,
    borderBottomWidth: rules.hair,
    borderBottomStyle: 'solid',
    borderBottomColor: colors.rule,
  },
  sub: { paddingLeft: space.s5 },
  title: { fontSize: sizes.body },
  live: { color: 'inherit', textDecoration: 'none', ':hover': { textDecoration: 'underline' } },
  pending: { color: colors.ink2 },
});

export const spec = stylex.create({
  swatches: {
    display: 'grid',
    gridTemplateColumns: { default: 'repeat(3, minmax(0, 1fr))', [bp.narrow]: 'repeat(2, minmax(0, 1fr))' },
    gap: space.s4,
  },
  chip: { height: '4.5rem', borderWidth: rules.hair, borderStyle: 'solid', borderColor: colors.ink, display: 'flex' },
  half: { flex: 1 },
  sw: { display: 'flex', flexDirection: 'column', gap: space.s1, fontSize: sizes.small, lineHeight: 1.4 },
  table: { width: '100%', borderCollapse: 'collapse', fontSize: sizes.small },
  th: {
    textAlign: 'left',
    paddingBlock: space.s2,
    paddingRight: space.s3,
    borderBottomWidth: rules.hair,
    borderBottomStyle: 'solid',
    borderBottomColor: colors.ink,
    fontWeight: 'normal',
  },
  td: {
    paddingBlock: space.s2,
    paddingRight: space.s3,
    borderBottomWidth: rules.hair,
    borderBottomStyle: 'solid',
    borderBottomColor: colors.rule,
    verticalAlign: 'baseline',
  },
  fail: { color: colors.signal },
  scaleRow: { display: 'grid', gridTemplateColumns: '5rem minmax(0, 1fr)', alignItems: 'baseline', gap: space.s4, paddingBlock: space.s2 },
  bar: { height: '0.75rem', backgroundColor: colors.ink },
  hair: { height: 0, borderTopStyle: 'solid', borderTopColor: colors.ink, borderTopWidth: rules.hair, width: '100%' },
  heavy: { height: 0, borderTopStyle: 'solid', borderTopColor: colors.ink, borderTopWidth: rules.heavy, width: '100%' },
  demo: { marginBlock: space.s4 },
  dl: { display: 'grid', gridTemplateColumns: { default: '10rem minmax(0, 1fr)', [bp.narrow]: '1fr' }, columnGap: space.s5, rowGap: space.s2, maxWidth: measure.text, fontSize: sizes.small },
  dont: { color: colors.ink2, textDecorationLine: 'line-through', textDecorationColor: colors.signal },
});
