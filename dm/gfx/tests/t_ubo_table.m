// uniform 句柄表 ABI：真實 GPU 讀第 0、31、34、37、63 項及越界啞資源，不帶遊戲資料。
// Uniform handle-table ABI: real GPU reads at 0, 31, 34, 37, 63 and the out-of-range dummy, without game data.
#include "../nvn/nvn_mtl.m"
int prog_key(const prog_t *p, unsigned stage, uint8_t key[8]) { (void)p; (void)stage; memset(key,0,8); return 0; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int cases, failed;
#define CHECK(s, a) do { cases++; if (!(a)) { fprintf(stderr,"FAIL %s\n",s); failed++; } } while (0)
int main(void) { @autoreleasepool {
    mtl_init();
    uint64_t *handles; if (posix_memalign((void **)&handles,getpagesize(),65536)) return 1;
    memset(handles,0,65536); mtl_pool_add(handles,65536);
    samp_par sampler={0}; sampler.lod_max=100; mtl_reg_samp(1,&sampler);
    for (int i=0;i<64;i++) {
        MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];
        td.storageMode=MTLStorageModeShared;td.usage=MTLTextureUsageShaderRead;
        id<MTLTexture> t=[g_dev newTextureWithDescriptor:td];res_add(t);
        uint8_t pixel[4]={(uint8_t)(i+1),0,0,255};[t replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:pixel bytesPerRow:4];
        tex_t texture={.magic=MAGIC('T','E','X',0),.serial=0xffffc000+i};
        texture.d=(nvn_texdesc){.width=1,.height=1,.depth=1,.levels=1,.target=NVN_TEXTURE_TARGET_2D,.format=NVN_FORMAT_RGBA8};
        serial_put(texture.serial,t);mtl_reg_tex(i+1,&texture,NULL);handles[i]=(uint64_t)(i+1)|(1u<<20);
    }
    S.ubo[1][3]=(p_bind_buf){.addr=(uint64_t)handles,.size=64*8};
    nvn_rbind texture={.kind=NVN_RB_TEXUT,.reg=3},sampl={.kind=NVN_RB_SAMPUT,.reg=3};
    CHECK("actual uniform length",ubo_table_count(1,&texture)==64);
    texture.off=8;CHECK("handle offset",ubo_table_count(1,&texture)==63);texture.off=0;
    NvShader *fs=[NvShader new];fs->stage=1;fs->rf.nb=1;fs->rf.b[0]=texture;
    NvProg *program=[NvProg new];program->sh[1]=fs;
    tex_t target=g_treg[38].t;R.rt.n=1;R.rt.color[0]=&target;
    CHECK("feedback scans descriptor 37",fbx_hazard(program)==1);
    memset(&R,0,sizeof R);
    mtl_sub_begin();uint64_t tg=ubo_table_gpu(1,&texture),sg=ubo_table_gpu(1,&sampl);
    const char *code="#include <metal_stdlib>\nusing namespace metal; struct T{uint n;array<texture2d<float>,1> e;};struct S{uint n;array<sampler,1> e;};struct A{constant T* t [[id(0)]];constant S* s [[id(1)]];};kernel void probe(constant A&a [[buffer(0)]],device float4*out [[buffer(1)]],constant uint*ix [[buffer(2)]],uint i [[thread_position_in_grid]]){out[i]=(&a.t->e[0])[min(ix[i],a.t->n)].sample((&a.s->e[0])[min(ix[i],a.s->n)],float2(.5),level(0));}";
    NSError *error=nil;id<MTLLibrary> lib=[g_dev newLibraryWithSource:[NSString stringWithUTF8String:code] options:nil error:&error];
    id<MTLFunction> fn=[lib newFunctionWithName:@"probe"];id<MTLComputePipelineState> ps=fn?[g_dev newComputePipelineStateWithFunction:fn error:&error]:nil;
    CHECK("probe pipeline",ps!=nil);if(!ps){fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);return 1;}
    id<MTLArgumentEncoder> ae=[fn newArgumentEncoderWithBufferIndex:0];
    CHECK("pointer argument ABI fits host slots",ae.encodedLength==16);
    id<MTLBuffer> args=[g_dev newBufferWithLength:ae.encodedLength options:MTLResourceStorageModeShared];
    uint64_t *slots=args.contents;slots[0]=tg;slots[1]=sg;res_add(args);
    uint32_t indices[]={0,31,34,37,63,64,8191};
    id<MTLBuffer> ix=[g_dev newBufferWithBytes:indices length:sizeof indices options:MTLResourceStorageModeShared];res_add(ix);
    id<MTLBuffer> output=[g_dev newBufferWithLength:7*16 options:MTLResourceStorageModeShared];res_add(output);
    id<MTL4ComputeCommandEncoder> en=enc_c_begin(NULL);
    [en setComputePipelineState:ps];
    id<MTL4ArgumentTable> table=g_ct;
    [table setAddress:args.gpuAddress atIndex:0];[table setAddress:output.gpuAddress atIndex:1];[table setAddress:ix.gpuAddress atIndex:2];
    [en setArgumentTable:table];[en dispatchThreads:MTLSizeMake(7,1,1) threadsPerThreadgroup:MTLSizeMake(7,1,1)];enc_c_end(en);
    mtl_sub_commit();mtl_finish();float *values=output.contents;
    for(int i=0;i<7;i++){float want=i<5?(indices[i]+1)/255.f:0;fprintf(stderr,"index=%u value=%g want=%g\n",indices[i],values[i*4],want);CHECK("correct original resource past index 31 / bounded dummy",fabsf(values[i*4]-want)<.001f);}
    S.ubo[1][3].size=0;CHECK("unbound uniform has zero elements",ubo_table_count(1,&texture)==0);
    // 可選：核對實際生成庫的反射與 Metal 參數塊長度；私有庫留在外部工作區。
    // Optional: verify generated-library reflection against Metal argument lengths; private libraries stay in the external workspace.
    if (getenv("DM_VERIFY_SHADER_ABI")) {
        shmap_load(); unsigned checked=0;
        NSArray *files=[NSFileManager.defaultManager contentsOfDirectoryAtPath:g_msl_dir error:nil];
        for (NSString *file in files) {
            if (![file hasSuffix:@"_b.json"]) continue;
            NSData *data=[NSData dataWithContentsOfFile:[g_msl_dir stringByAppendingPathComponent:file]];
            NSDictionary *json=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            int table=0; for (NSDictionary *b in json[@"bindings"]) table|=[b[@"kind"] isEqual:@"tex_ubo_table"];
            if (!table) continue;
            NvShader *shader=shader_get([file stringByDeletingPathExtension],1);
            CHECK("generated terrain shader ABI",shader && shader->ae && shader->rf.bindless);
            checked++;
        }
        CHECK("all 21 referenced terrain variants checked",checked>=21);
        printf("GENERATED_UBO_SHADER_ABI checked=%u\n",checked);
    }
    mtl_pool_del(handles);free(handles);
    printf("UBO_TABLE cases=%d failed=%d REAL_METAL_GPU\n",cases,failed);return failed!=0;
} }
