import * as stylex from '@stylexjs/stylex';
import { colors, space, rules, bp } from '../tokens.stylex';

export const chrome = stylex.create({
  header: {
    display: 'flex',
    justifyContent: 'space-between',
    alignItems: 'baseline',
    gap: space.s4,
    paddingTop: space.s5,
    paddingBottom: space.s3,
    borderBottomWidth: rules.hair,
    borderBottomStyle: 'solid',
    borderBottomColor: colors.ink,
  },
  group: { display: 'flex', gap: space.s3, alignItems: 'baseline', flexWrap: 'wrap', minWidth: 0 },
  hideNarrow: { display: { default: 'inline', [bp.narrow]: 'none' } },
  home: { color: 'inherit', textDecoration: 'none' },
  current: { color: colors.signal },
  footer: {
    display: 'grid',
    gridTemplateColumns: { default: '1fr auto 1fr', [bp.narrow]: '1fr 1fr' },
    gap: space.s4,
    alignItems: 'baseline',
    marginTop: space.s8,
    paddingTop: space.s3,
    paddingBottom: space.s6,
    borderTopWidth: rules.hair,
    borderTopStyle: 'solid',
    borderTopColor: colors.ink,
  },
  center: { textAlign: 'center', display: { default: 'block', [bp.narrow]: 'none' } },
  end: { textAlign: 'right' },
  nav: { color: 'inherit', textDecoration: 'none', ':hover': { textDecoration: 'underline' } },
  switch: {
    backgroundColor: 'transparent',
    appearance: 'none',
    borderWidth: 0,
    padding: 0,
    cursor: 'pointer',
    textDecoration: { default: 'none', ':hover': 'underline' },
  },
});
