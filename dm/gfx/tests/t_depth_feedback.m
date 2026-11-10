// 深度回授回歸：真實副本、掛起的清除、唯讀重用、寫後失效；不需要遊戲資料。
// Depth feedback regression: real copies, pending clears, read-only reuse, write invalidation; no game data required.
#include "../nvn/nvn_mtl.m"
int prog_key(const prog_t *p, unsigned stage, uint8_t key[8]) { (void)p; (void)stage; memset(key, 0, 8); return 0; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int cases, failed;
#define CHECK(s, a) do { cases++; if (!(a)) { fprintf(stderr, "FAIL %s\n", s); failed++; } } while (0)

static void check_pixels(id<MTLTexture> snapshot, float expected) {
    rp_end(); mtl_sub_commit(); mtl_finish();
    NSError *error = nil;
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal; kernel void sample_depth(depth2d<float> t [[texture(0)]],device float *o [[buffer(0)]],uint2 p [[thread_position_in_grid]]){o[p.y*8+p.x]=t.read(p);}";
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:source options:nil error:&error];
    id<MTLComputePipelineState> ps = [g_dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"sample_depth"] error:&error];
    CHECK("probe shader", ps != nil);
    if (!ps) return;
    id<MTLBuffer> out = [g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [g_q commandBuffer];
    id<MTLComputeCommandEncoder> en = [cb computeCommandEncoder];
    [en setComputePipelineState:ps]; [en setTexture:snapshot atIndex:0]; [en setBuffer:out offset:0 atIndex:0];
    [en dispatchThreads:MTLSizeMake(8,8,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];
    [en endEncoding]; [cb commit]; [cb waitUntilCompleted];
    CHECK("GPU completion", cb.status == MTLCommandBufferStatusCompleted);
    float *pixels = out.contents;
    for (int i = 0; i < 64; i++) CHECK("cleared depth reached snapshot", fabsf(pixels[i] - expected) < 0.001f);
}

int main(void) { @autoreleasepool {
    mtl_init();
    const MTLPixelFormat formats[] = {MTLPixelFormatDepth16Unorm, MTLPixelFormatDepth32Float, MTLPixelFormatDepth32Float_Stencil8};
    const uint32_t nvnformats[] = {NVN_FORMAT_DEPTH16, NVN_FORMAT_DEPTH32F, NVN_FORMAT_DEPTH32F_STENCIL8};
    for (int f = 0; f < 3; f++) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:formats[f] width:8 height:8 mipmapped:NO];
        td.storageMode = MTLStorageModePrivate; td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        id<MTLTexture> original = [g_dev newTextureWithDescriptor:td]; res_add(original);
        tex_t depth = {.magic=MAGIC('T','E','X',0)}; depth.serial = 0xffffd800 + f;
        depth.d = (nvn_texdesc){.width=8,.height=8,.depth=1,.levels=1,.target=NVN_TEXTURE_TARGET_2D,.format=nvnformats[f]};
        serial_put(depth.serial, original); mtl_reg_tex(57, &depth, NULL);
        NvShader *fs = [NvShader new]; fs->stage=1; fs->rf.nb=1; fs->rf.b[0]=(nvn_rbind){.kind=NVN_RB_TEX,.reg=0,.cnt=1};
        NvProg *pr = [NvProg new]; pr->sh[1]=fs;
        for (int step = 0; step < 2; step++) {
            mtl_sub_begin(); memset(&R,0,sizeof R); R.has_rt=1; R.rt.depth=&depth;
            R.clear_d=1; R.cd=step ? .75 : .25; R.clear_s=f==2; R.cs=19;
            S.tex[1][0]=57; S.ds.dt=1; S.ds.dw=0; S.ds.df=NVN_COMPARE_FUNC_ALWAYS;
            CHECK("depth sampling hazard", fbx_hazard(pr)==(1u<<8));
            fbx_prepare(pr);
            id<MTLTexture> copy = fbx_bind(57, original);
            CHECK("sample a copy, not the live depth attachment", copy && copy != original);
            CHECK("copy covers depth", g_fbx_mask==(1u<<8));
            CHECK("same-pass read-only reuse", fbx_needs_refresh(pr)==0);
            g_fbx_dirty |= 1u<<8;
            CHECK("depth write invalidates copy", fbx_needs_refresh(pr)==(1u<<8));
            g_fbx_dirty=0;
            // 缺少的附件也必須刷新，不能因已有另一張副本而漏掉。
            // A newly sampled attachment must refresh even if another copy already exists.
            g_fbx_mask=0; CHECK("uncopied attachment refresh", fbx_needs_refresh(pr)==(1u<<8)); g_fbx_mask=1u<<8;
            rp_begin_ex(0);
            CHECK("new render pass", g_enc!=nil);
            check_pixels(copy, step ? .75f : .25f);
            CHECK("pass boundary invalidates bindings", g_fbx_n==0);
        }
    }
    printf("DEPTH_FEEDBACK cases=%d failed=%d REAL_METAL_GPU\n", cases, failed);
    return failed!=0;
} }
