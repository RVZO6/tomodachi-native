// 從獨立研究原型移入的安全預檢；不寫存檔、不呼叫遊戲、不排程 UIKit 工作。
// Safe preflight adapted from the independent research prototype; no save writes, guest calls, or UIKit jobs.
#include "dm_mii_new.h"
#include <stdio.h>
#include <string.h>

static int fail(char *e, size_t cap, const char *s) {
    if (e && cap) snprintf(e, cap, "%s", s);
    return -1;
}
static uint32_t get32(const uint8_t *p) {
    return p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
int dm_mii_new_plan_make(const dm_mii_input *input, const dm_mii_slot roster[DM_MII_SLOTS],
                         dm_mii_new_plan *out, char *e, size_t cap) {
    const dm_mii_ltd *view = dm_mii_input_view(input);
    if (!view || !roster || !out) return fail(e, cap, "Invalid new-islander plan request.");
    const uint8_t *b = view->bytes;
    unsigned count = 0;
    for (unsigned i = 0; i < DM_MII_SLOTS; i++) {
        // 即使名字損毀也拒絕相同識別碼；initialized 不是客體佔用位元。
        // Reject matching identities even with invalid names; initialized is not guest occupancy.
        if (!memcmp(roster[i].raw + 4, b + 8, 16))
            return fail(e, cap, "Source identity already exists. Duplicate creation is not supported.");
        count += !!roster[i].initialized;
    }
    if (count == DM_MII_SLOTS)
        return fail(e, cap, "The stored roster is full. Guest capacity checks are also required.");
    dm_mii_new_plan p = {0};
    memcpy(p.appearance, b + 8, sizeof p.appearance);
    for (unsigned i = 0; i < 18; i++) p.scalar[i] = get32(b + 0xa0 + 4*i);
    memcpy(p.name, b + 0xe8, sizeof p.name);
    memcpy(p.pronounced, b + 0x128, sizeof p.pronounced);
    memcpy(p.preferences, b + 0x1a8, sizeof p.preferences);
    p.gaps = DM_MII_NEW_RUNTIME | DM_MII_NEW_MISC | DM_MII_NEW_PREFERENCES |
             DM_MII_NEW_BIRTHDAY | DM_MII_NEW_VOICE_PRESET | DM_MII_NEW_SEQUENCE;
    if (view->canvas_size) p.gaps |= DM_MII_NEW_PAINT;
    // 完整檔案與未知中繼資料仍由 input 持有；不可只留這份部分解碼的計畫。
    // Input retains the complete file and unknown metadata; do not retain only this decoded plan.
    *out = p;
    return 0;
}
int dm_mii_new_can_execute(const dm_mii_new_plan *plan) { (void)plan; return 0; }
