// 經驗證的匯入資料擁有者；替換與新增路徑共用，不借用檔案選取器的緩衝區。
// Owned validated import input shared by replacement and creation; never borrows picker buffers.
#pragma once
#include "dm_mii_codec.h"

typedef struct dm_mii_input dm_mii_input;
dm_mii_input *dm_mii_input_open(const void *bytes, size_t size, char *error, size_t cap);
// 檢視與壓縮幀均借用擁有者；關閉前不得釋放，也不得修改。
// The view and compressed frames borrow the owner; keep it alive and immutable until use ends.
const dm_mii_ltd *dm_mii_input_view(const dm_mii_input *input);
void dm_mii_input_close(dm_mii_input *input);
// 供有多個返回點的原生呼叫者使用 cleanup 屬性。
// Cleanup attribute helper for native callers with multiple return paths.
void dm_mii_input_cleanup(dm_mii_input **input);
int dm_mii_input_replace(const dm_mii_input *input, void *mii, size_t mii_size,
                         void *player, size_t player_size, unsigned slot,
                         dm_mii_paint_plan *paint, char *error, size_t cap);
