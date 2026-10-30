# The differential test (diff.c) of the NEON block validator: diff.c and
# the runtime built for aarch64, statically, and run under qemu-aarch64,
# its stream checked by check.exe as the native one is. qemu checks
# what it computes, not how fast. Skipped, saying so, where the cross
# compiler or qemu isn't installed.
rt=$1
for tool in aarch64-linux-gnu-gcc qemu-aarch64; do
  if ! command -v $tool > /dev/null 2>&1; then
    echo "neon: skipped, no $tool"
    exit 0
  fi
done
set -e
aarch64-linux-gnu-gcc -O2 -I "$rt" -include ren_rt.h -c "$rt/ren_rt.c" -o rt_neon.o
aarch64-linux-gnu-gcc -O2 -static -I "$rt" diff.c rt_neon.o -o diff_neon.exe -lm -lpthread
qemu-aarch64 ./diff_neon.exe stream 20 | ./check.exe
