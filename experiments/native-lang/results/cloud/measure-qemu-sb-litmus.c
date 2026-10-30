/* store-buffering litmus: x=1; r1=y || y=1; r2=x with seq_cst store + seq_cst load (clang: stlr/ldar on aarch64,
   no dmb). r1==0 && r2==0 is forbidden by C11 and by ARMv8 (RCsc). Built with -DFENCE: relaxed ops + fence(SC). */
#include <pthread.h>
#include <stdio.h>
#include <stdatomic.h>
#define N 2000000
static _Atomic long x, y, go; static long r1[N], r2[N]; static _Atomic long turn0, turn1;
static void *t0(void *a){ for (long i=0;i<N;i++){ while (atomic_load(&turn0)!=i); 
#ifdef FENCE
 atomic_store_explicit(&x,i+1,memory_order_relaxed); atomic_thread_fence(memory_order_seq_cst); r1[i]=atomic_load_explicit(&y,memory_order_relaxed);
#else
 atomic_store(&x,i+1); r1[i]=atomic_load(&y);
#endif
 atomic_store(&turn0,-1);} return 0;}
static void *t1(void *a){ for (long i=0;i<N;i++){ while (atomic_load(&turn1)!=i);
#ifdef FENCE
 atomic_store_explicit(&y,i+1,memory_order_relaxed); atomic_thread_fence(memory_order_seq_cst); r2[i]=atomic_load_explicit(&x,memory_order_relaxed);
#else
 atomic_store(&y,i+1); r2[i]=atomic_load(&x);
#endif
 atomic_store(&turn1,-1);} return 0;}
int main(void){ pthread_t a,b; atomic_store(&turn0,-1); atomic_store(&turn1,-1); pthread_create(&a,0,t0,0); pthread_create(&b,0,t1,0);
 long bad=0; for (long i=0;i<N;i++){ atomic_store(&turn0,i); atomic_store(&turn1,i); while(atomic_load(&turn0)!=-1||atomic_load(&turn1)!=-1); if (r1[i]<i+1 && r2[i]<i+1) bad++; }
 pthread_join(a,0); pthread_join(b,0); printf("forbidden SB outcomes: %ld of %d\n", bad, N); return bad!=0; }
