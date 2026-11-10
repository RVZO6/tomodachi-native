// .ltd v3 與本作存檔欄位的有界編解碼；不做檔案 IO，不執行遊戲程式。
// Bounded .ltd v3 and title-save field codec; no file IO or guest execution.
#pragma once
#include <stddef.h>
#include <stdint.h>
#define DM_MII_SLOTS 70
#define DM_MII_PAINTS 72
#define DM_MII_LTD_LIMIT (2u * 1024u * 1024u)
#define DM_MII_LTD_FIXED 428u
#define DM_MII_RAW_BYTES 156u

// 解析結果只借用輸入記憶體；呼叫者須維持整份不可變資料的生命週期。
// Parsed views borrow the input: the caller must keep the complete immutable buffer alive.
typedef struct {
    const uint8_t *bytes;
    size_t size;
    const uint8_t *canvas, *ugc;
    size_t canvas_size, ugc_size;
} dm_mii_ltd;
typedef struct {
    // 只表示存檔內有非零識別碼與有效名字，不是遊戲執行期的佔用查詢。
    // Stored-record eligibility (nonzero identity and valid name), not a live runtime occupancy query.
    int initialized;
    uint8_t raw[DM_MII_RAW_BYTES], name[64];
} dm_mii_slot;
typedef struct {
    int write_paint;
    unsigned paint_index;
} dm_mii_paint_plan;
int dm_mii_ltd_parse(const void *bytes, size_t size, dm_mii_ltd *out, char *error, size_t cap);
int dm_mii_roster(const void *mii, size_t size, dm_mii_slot out[DM_MII_SLOTS], char *error, size_t cap);
// 只替換現有紀錄；slot 是 0..69，不建立居民，也不設定執行期佔用位元。
// Replacement only: slot is zero-based 0..69; no islander creation or runtime occupancy writes.
int dm_mii_apply(void *mii, size_t mii_size, void *player, size_t player_size,
                 const dm_mii_ltd *ltd, unsigned slot, dm_mii_paint_plan *paint,
                 char *error, size_t cap);
int dm_mii_export_fixed(const void *mii, size_t size, unsigned slot,
                       uint8_t out[DM_MII_LTD_FIXED], uint32_t *paint_index, char *error, size_t cap);
// 嚴格單幀與解碼大小檢查；輸出壓縮幀長度，不交出解壓資料。
// Strict single-frame and decoded-size validation; return compressed frame length, not decoded content.
int dm_mii_zstd_frame(const void *bytes, size_t size, size_t expected, size_t *frame_size);
