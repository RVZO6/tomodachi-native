// 新居民的獨立預檢；尚未提供可執行的客體配接器。
// Independent new-islander preflight; no executable guest adapter is available yet.
#pragma once
#include "dm_mii_input.h"

enum dm_mii_new_gap {
    DM_MII_NEW_RUNTIME = 1u << 0,
    DM_MII_NEW_MISC = 1u << 1,
    DM_MII_NEW_PREFERENCES = 1u << 2,
    DM_MII_NEW_BIRTHDAY = 1u << 3,
    DM_MII_NEW_VOICE_PRESET = 1u << 4,
    DM_MII_NEW_SEQUENCE = 1u << 5,
    DM_MII_NEW_PAINT = 1u << 6
};
typedef struct {
    uint8_t appearance[152];
    // 保留 LTD 原始順序的全部十八個純量；不猜測未驗證的客體欄位。
    // Keep all eighteen scalars in LTD order; do not guess unverified guest fields.
    uint32_t scalar[18];
    uint8_t name[64], pronounced[128], preferences[3];
    unsigned gaps;
} dm_mii_new_plan;
// 輸出只是中立資料，不是已建構的客體 profile；失敗不改輸出。
// Output is neutral data, not a constructed guest profile; errors leave output unchanged.
// 存檔快照僅供預檢，不能判定客體容量、進度或房屋資格。
// A save snapshot is advisory; it cannot establish guest capacity, progression, or house eligibility.
int dm_mii_new_plan_make(const dm_mii_input *input,
                         const dm_mii_slot roster[DM_MII_SLOTS],
                         dm_mii_new_plan *out, char *error, size_t cap);
// 即使呼叫者清除 gaps，仍停用所有版本；不可用計畫內容充當執行授權。
// Disabled for every build even if callers clear gaps; plan data is not execution authorization.
int dm_mii_new_can_execute(const dm_mii_new_plan *plan);
