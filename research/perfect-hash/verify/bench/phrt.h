/* The runtime half: what every emitted perfect-hash match calls. */
#include <arm_neon.h>
#include <stdint.h>
#include <string.h>

/* row n: 0..n-1 then 0x80, which tbl turns into 0 */
static const uint8_t ph_masks[17][16] __attribute__((aligned(16))) = {
#define R(n) {0<n?0:128,1<n?1:128,2<n?2:128,3<n?3:128,4<n?4:128,5<n?5:128,6<n?6:128,7<n?7:128,8<n?8:128,9<n?9:128,10<n?10:128,11<n?11:128,12<n?12:128,13<n?13:128,14<n?14:128,15<n?15:128}
  R(0),R(1),R(2),R(3),R(4),R(5),R(6),R(7),R(8),R(9),R(10),R(11),R(12),R(13),R(14),R(15),R(16)
#undef R
};

/* Lemire's page-safe load: 16 bytes at s, unless that crosses a 4 KB
   boundary, then the 16 bytes before the boundary shifted down. */
__attribute__((no_sanitize("address"), always_inline))
static inline uint8x16_t ph_load_paged(const char *s, size_t n) {
  uintptr_t a = (uintptr_t)s;
  size_t off = a & 4095;
  if (__builtin_expect(off <= 4080, 1)) return vld1q_u8((const uint8_t *)s);
  size_t o = off > 4096 - n ? 0 : off - 4080;
  uint8x16_t raw = vld1q_u8((const uint8_t *)(a - o));
  uint8x16_t idx = vaddq_u8(vld1q_u8(ph_masks[16]), vdupq_n_u8((uint8_t)o));
  return vqtbl1q_u8(raw, idx);
}

/* With a runtime that keeps 16 readable bytes after every string's end
   (padding each owner's allocation by 15 bytes), the check goes. */
__attribute__((no_sanitize("address"), always_inline))
static inline uint8x16_t ph_load_padded(const char *s, size_t n) {
  (void)n;
  return vld1q_u8((const uint8_t *)s);
}

__attribute__((always_inline))
static inline int ph_eq16(uint8x16_t raw, size_t n, const uint8_t *stored) {
  uint8x16_t in = vqtbl1q_u8(raw, vld1q_u8(ph_masks[n]));
  uint8x16_t eq = vceqq_u8(in, vld1q_u8(stored));
  uint8x8_t nar = vshrn_n_u16(vreinterpretq_u16_u8(eq), 4);
  return vget_lane_u64(vreinterpret_u64_u8(nar), 0) == ~0ULL;
}

/* masks keeping the first n bytes of a 16-byte key, as two words */
#define LO(n) ((n) >= 8 ? ~0ULL : (1ULL << (8 * (n))) - 1)
#define HI(n) ((n) <= 8 ? 0ULL : (n) >= 16 ? ~0ULL : (1ULL << (8 * ((n) - 8))) - 1)
static const uint64_t ph_lo[17] = {LO(0),LO(1),LO(2),LO(3),LO(4),LO(5),LO(6),LO(7),LO(8),LO(9),LO(10),LO(11),LO(12),LO(13),LO(14),LO(15),LO(16)};
static const uint64_t ph_hi[17] = {HI(0),HI(1),HI(2),HI(3),HI(4),HI(5),HI(6),HI(7),HI(8),HI(9),HI(10),HI(11),HI(12),HI(13),HI(14),HI(15),HI(16)};
#undef LO
#undef HI
