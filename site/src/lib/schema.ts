// Data contracts for generated figures. `ren doc` should eventually emit these shapes
// from real signatures; until then they are hand-authored.

export type Effect = 'IO' | 'ALLOC' | 'FAIL' | 'ASYNC';
export const EFFECTS: readonly Effect[] = ['IO', 'ALLOC', 'FAIL', 'ASYNC'];

export interface Signature {
  name: string;
  module?: string;
  params: { name: string; type: string }[];
  uses: string[];
  returns: string;
  errors: string[];
  effects: Effect[];
}

export interface MemoryRow {
  label: string;
  fields: { name: string; bytes: number; kind?: 'data' | 'pad' | 'hot' }[];
}

export interface Trace {
  ticks: number;           // simulated time span, in ticks
  step: number;            // axis label interval
  lanes: string[];
  messages: { from: number; to: number; t0: number; t1: number; label?: string }[];
  events: { lane: number; t: number; label: string; fault?: boolean }[];
}
