/* fuzz_target.c: libFuzzer entry (clang -fsanitize=fuzzer,address). */
#include <stddef.h>
#include <stdint.h>
int fuzz_one(const uint8_t *data, size_t len);
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t len) { fuzz_one(data, len); return 0; }
