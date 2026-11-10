// 先複製再解析；所有借用指標只指向本物件持有的不可變資料。
// Copy before parsing; every borrowed pointer refers to immutable data held by this object.
#include "dm_mii_input.h"
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

struct dm_mii_input { uint8_t *owned; dm_mii_ltd view; };
static int fail(char *e, size_t cap, const char *s) {
    if (e && cap) snprintf(e, cap, "%s", s);
    return -1;
}
dm_mii_input *dm_mii_input_open(const void *bytes, size_t size, char *e, size_t cap) {
    if (!bytes || size < 436 || size > DM_MII_LTD_LIMIT) {
        fail(e, cap, "Invalid Mii file size."); return NULL;
    }
    dm_mii_input *p = calloc(1, sizeof *p);
    if (!p) { fail(e, cap, "Cannot allocate Mii input."); return NULL; }
    p->owned = malloc(size);
    if (!p->owned) { free(p); fail(e, cap, "Cannot allocate Mii input."); return NULL; }
    memcpy(p->owned, bytes, size);
    if (dm_mii_ltd_parse(p->owned, size, &p->view, e, cap)) {
        dm_mii_input_close(p); return NULL;
    }
    return p;
}
const dm_mii_ltd *dm_mii_input_view(const dm_mii_input *p) { return p ? &p->view : NULL; }
void dm_mii_input_close(dm_mii_input *p) { if (p) { free(p->owned); free(p); } }
void dm_mii_input_cleanup(dm_mii_input **p) { if (p) { dm_mii_input_close(*p); *p = NULL; } }
int dm_mii_input_replace(const dm_mii_input *input, void *mii, size_t mn,
                         void *player, size_t pn, unsigned slot,
                         dm_mii_paint_plan *paint, char *e, size_t cap) {
    if (!input) return fail(e, cap, "Choose a valid Mii file first.");
    // 保留原編解碼器的已初始化欄位檢查；此入口不能建立居民。
    // Retain the codec's initialized-slot guard; this entry point cannot create an islander.
    return dm_mii_apply(mii, mn, player, pn, &input->view, slot, paint, e, cap);
}
