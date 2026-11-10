// 固定容量的診斷環；音頻與圖形寫入不等待、不配置、不碰磁碟。
// Fixed-capacity diagnostic rings; audio/graphics writers never wait, allocate, or touch disk.
#pragma once
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#ifdef __APPLE__
#include <TargetConditionals.h>
#endif

enum { DM_DIAG_AUDIO = 1, DM_DIAG_ENQUEUE, DM_DIAG_PRESENT, DM_DIAG_GPU, DM_DIAG_DISPLAY, DM_DIAG_LIFECYCLE };
typedef struct { uint64_t ns, id, a, b, c, d; uint32_t kind, flags; } dm_diag_event;
enum { DM_DIAG_EVENTS = 65536, DM_DIAG_LOGS = 2048, DM_DIAG_LOG_BYTES = 1024 };
typedef struct { uint64_t ns, seq; uint32_t len; char text[DM_DIAG_LOG_BYTES]; } dm_diag_log;
typedef struct {
    uint64_t cutoff_ns, start_ns, enabled_since_ns, event_drops, log_drops, event_overwrites, log_overwrites;
    size_t event_count, log_count;
    dm_diag_event *events;
    dm_diag_log *logs;
} dm_diag_snapshot;

#if defined(DM_DIAG_IMPLEMENTATION)
#define DM_DIAG_OPTIONAL
#elif defined(__APPLE__)
#define DM_DIAG_OPTIONAL __attribute__((weak_import))
#else
#define DM_DIAG_OPTIONAL __attribute__((weak))
#endif
void dm_diag_record(uint32_t kind, uint64_t id, uint64_t a, uint64_t b, uint64_t c, uint64_t d) DM_DIAG_OPTIONAL;
static inline void dm_diag_emit(uint32_t kind, uint64_t id, uint64_t a, uint64_t b, uint64_t c, uint64_t d) {
#ifdef DM_DIAG_IMPLEMENTATION
    dm_diag_record(kind, id, a, b, c, d);
#elif defined(__APPLE__) && !TARGET_OS_IPHONE
    (void)kind;(void)id;(void)a;(void)b;(void)c;(void)d;
#else
    if (dm_diag_record) dm_diag_record(kind, id, a, b, c, d);
#endif
}
uint64_t dm_diag_now(void);
void dm_diag_configure(int enabled);
int dm_diag_enabled(void);
void dm_diag_log_write(const char *bytes, size_t length);
size_t dm_diag_logs_after(uint64_t *cursor, char *out, size_t capacity);
dm_diag_snapshot *dm_diag_take(uint64_t cutoff_ns, unsigned history_seconds);
void dm_diag_snapshot_free(dm_diag_snapshot *snapshot);
void dm_diag_write_events(FILE *out, const dm_diag_snapshot *snapshot);
void dm_diag_write_logs(FILE *out, const dm_diag_snapshot *snapshot);
