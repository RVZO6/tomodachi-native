// 只解碼、限制視窗與輸出大小；不讓匯入檔案要求無界分配。
// Decode only, with bounded window and output sizes; imported files cannot request unbounded allocation.
#define ZSTD_STATIC_LINKING_ONLY
#define ZSTDLIB_VISIBILITY __attribute__((visibility("hidden")))
#pragma GCC visibility push(hidden)
#include "../../third_party/zstd/zstddeclib.c"
#pragma GCC visibility pop
#include "dm_mii_codec.h"
int dm_mii_zstd_frame(const void *bytes, size_t size, size_t expected, size_t *frame_size) {
    ZSTD_frameHeader h;
    size_t r = ZSTD_getFrameHeader(&h, bytes, size);
    if (r || h.frameType != ZSTD_frame || h.frameContentSize != expected || h.windowSize > 1024u * 1024u) return -1;
    size_t n = ZSTD_findFrameCompressedSize(bytes, size);
    if (ZSTD_isError(n) || !n || n > size) return -1;
    void *out = malloc(expected);
    if (!out) return -1;
    r = ZSTD_decompress(out, expected, bytes, n);
    free(out);
    if (ZSTD_isError(r) || r != expected) return -1;
    *frame_size = n;
    return 0;
}
