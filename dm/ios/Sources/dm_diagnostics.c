// 診斷資料只留在兩個預配置環裡（約 6 MiB）；擷取才複製，滿了覆寫最舊資料。
// Diagnostic data stays in two preallocated rings (about 6 MiB); copy only on capture, overwrite oldest when full.
#define DM_DIAG_IMPLEMENTATION
#include "dm_diagnostics.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "Diagnostic counters must be lock-free.");
#ifdef __APPLE__
#include <mach/mach_time.h>
#endif

static dm_diag_event events[DM_DIAG_EVENTS];
static dm_diag_log logs[DM_DIAG_LOGS];
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static _Atomic int enabled;
static _Atomic uint64_t event_drops, log_drops;
static uint64_t event_seq, log_seq, enabled_since;
#ifdef __APPLE__
static mach_timebase_info_data_t timebase;
static pthread_once_t clock_once = PTHREAD_ONCE_INIT;
static void init_clock(void) { mach_timebase_info(&timebase); }
#endif
uint64_t dm_diag_now(void) {
#ifdef __APPLE__
    pthread_once(&clock_once, init_clock);
    uint64_t t = mach_absolute_time();
    return (t / timebase.denom) * timebase.numer + (t % timebase.denom) * timebase.numer / timebase.denom;
#else
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000000ull + t.tv_nsec;
#endif
}
void dm_diag_configure(int on) {
    uint64_t now = dm_diag_now();
    pthread_mutex_lock(&mu);
    if (!!on != atomic_load(&enabled)) {
        atomic_store(&enabled, 0); event_seq = 0; enabled_since = now;
        atomic_store(&event_drops, 0); atomic_store(&log_drops, 0);
        atomic_store_explicit(&enabled, !!on, memory_order_release);
    }
    pthread_mutex_unlock(&mu);
}
int dm_diag_enabled(void) { return atomic_load_explicit(&enabled, memory_order_relaxed); }
void dm_diag_record(uint32_t kind, uint64_t id, uint64_t a, uint64_t b, uint64_t c, uint64_t d) {
    if (!dm_diag_enabled()) return;
    uint64_t ns = dm_diag_now();
    if (pthread_mutex_trylock(&mu)) { atomic_fetch_add_explicit(&event_drops, 1, memory_order_relaxed); return; }
    if (atomic_load(&enabled)) events[event_seq++ % DM_DIAG_EVENTS] = (dm_diag_event){ns,id,a,b,c,d,kind,0};
    pthread_mutex_unlock(&mu);
}
void dm_diag_log_write(const char *bytes, size_t n) {
    if (!bytes || !n) return;
    if (n > 16384) { atomic_fetch_add(&log_drops, n - 16384); n = 16384; }
    if (pthread_mutex_trylock(&mu)) { atomic_fetch_add_explicit(&log_drops, n, memory_order_relaxed); return; }
    while (n) {
        size_t k = n < DM_DIAG_LOG_BYTES ? n : DM_DIAG_LOG_BYTES;
        dm_diag_log *l = &logs[log_seq % DM_DIAG_LOGS];
        l->ns = dm_diag_now(); l->seq = ++log_seq; l->len = (uint32_t)k; memcpy(l->text, bytes, k);
        n -= k; bytes += k;
    }
    pthread_mutex_unlock(&mu);
}
size_t dm_diag_logs_after(uint64_t *cursor, char *out, size_t cap) {
    size_t n = 0;
    pthread_mutex_lock(&mu);
    uint64_t first = log_seq > DM_DIAG_LOGS ? log_seq - DM_DIAG_LOGS : 0;
    if (*cursor > log_seq || *cursor < first) *cursor = first;
    while (*cursor < log_seq) {
        const dm_diag_log *l = &logs[*cursor % DM_DIAG_LOGS];
        if (l->len > cap - n) break;
        memcpy(out + n, l->text, l->len); n += l->len; ++*cursor;
    }
    pthread_mutex_unlock(&mu); return n;
}
dm_diag_snapshot *dm_diag_take(uint64_t cutoff, unsigned seconds) {
    dm_diag_snapshot *s = calloc(1, sizeof *s); if (!s) return NULL;
    s->events = malloc(sizeof events); s->logs = malloc(sizeof logs);
    if (!s->events || !s->logs) { dm_diag_snapshot_free(s); return NULL; }
    if (!cutoff) cutoff = dm_diag_now();
    uint64_t span = (uint64_t)seconds * 1000000000ull, start = cutoff > span ? cutoff - span : 0;
    s->cutoff_ns = cutoff; s->start_ns = start;
    pthread_mutex_lock(&mu);
    s->enabled_since_ns = enabled_since;
    if (enabled_since > start) start = enabled_since;
    s->start_ns = start;
    s->event_drops = atomic_load(&event_drops); s->log_drops = atomic_load(&log_drops);
    s->event_overwrites = event_seq > DM_DIAG_EVENTS ? event_seq - DM_DIAG_EVENTS : 0;
    s->log_overwrites = log_seq > DM_DIAG_LOGS ? log_seq - DM_DIAG_LOGS : 0;
    for (uint64_t i = s->event_overwrites; i < event_seq; ++i) {
        dm_diag_event e = events[i % DM_DIAG_EVENTS]; if (e.ns >= start && e.ns <= cutoff) s->events[s->event_count++] = e;
    }
    for (uint64_t i = s->log_overwrites; i < log_seq; ++i) {
        dm_diag_log l = logs[i % DM_DIAG_LOGS]; if (l.ns >= start && l.ns <= cutoff) s->logs[s->log_count++] = l;
    }
    pthread_mutex_unlock(&mu); return s;
}
void dm_diag_snapshot_free(dm_diag_snapshot *s) { if (s) { free(s->events); free(s->logs); free(s); } }
void dm_diag_write_events(FILE *f, const dm_diag_snapshot *s) {
    fputs("monotonic_ns,kind,id,a,b,c,d\n", f);
    for (size_t i=0; i<s->event_count; ++i) { const dm_diag_event *e=&s->events[i];
        fprintf(f,"%llu,%u,%llu,%llu,%llu,%llu,%llu\n",(unsigned long long)e->ns,e->kind,(unsigned long long)e->id,(unsigned long long)e->a,(unsigned long long)e->b,(unsigned long long)e->c,(unsigned long long)e->d);
    }
}
void dm_diag_write_logs(FILE *f, const dm_diag_snapshot *s) {
    int line = 1;
    for (size_t i=0; i<s->log_count; ++i) { const dm_diag_log *l=&s->logs[i];
        for (uint32_t j=0;j<l->len;++j) { if (line) fprintf(f,"[%llu] ",(unsigned long long)l->ns); fputc(l->text[j],f); line=l->text[j]=='\n'; }
    }
    if (!line) fputc('\n',f);
}
