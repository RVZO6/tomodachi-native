// 依公開 .ltd v3 格式與玩家副本的差分量測實作；欄位用存檔自身的雜湊索引定位，不硬套版本偏移。
// Implemented from the public .ltd v3 format and differential tests on private save copies; locate fields through the save's hash index, not version offsets.
#include "dm_mii_codec.h"
#include <stdio.h>
#include <string.h>
#include <stdarg.h>

static uint32_t u32(const void *v) { const uint8_t *p = v; return (uint32_t)p[0] | (uint32_t)p[1]<<8 | (uint32_t)p[2]<<16 | (uint32_t)p[3]<<24; }
static void put32(void *v, uint32_t x) { uint8_t *p=v; for (int i=0;i<4;i++) p[i]=(uint8_t)(x>>(8*i)); }
static int fail(char *e, size_t cap, const char *fmt, ...) { if (e && cap) { va_list a; va_start(a,fmt); vsnprintf(e,cap,fmt,a); va_end(a); } return -1; }
static int utf16(const uint8_t *p, size_t units, int empty) {
    if (!(empty & 1) && !p[0] && !p[1]) return 0;
    for (size_t i=0;i<units;i++) { unsigned c=p[i*2]|(unsigned)p[i*2+1]<<8;
        if (!c) return 1;
        if ((c<32 && !(empty & 2)) || (c>=0xdc00 && c<=0xdfff)) return 0;
        if (c>=0xd800 && c<=0xdbff) { if (++i>=units) return 0; c=p[i*2]|(unsigned)p[i*2+1]<<8; if(c<0xdc00||c>0xdfff)return 0; }
    }
    return 0;
}
typedef struct { size_t offset, stride; uint32_t tag; } field;
// .ltd 位址、存檔欄位雜湊、每位居民的位元組數；雜湊是格式中繼資料，不是遊戲內容。
// .ltd offset, save field hash, bytes per islander; hashes are format metadata, not game content.
static const field fields[] = {
 {0x04,156,0x881ca27a}, {0xa0,4,0x43cd364f}, {0xa4,4,0xcd8dbaf8},
 {0xa8,4,0x25b48224}, {0xac,4,0x607ba160}, {0xb0,4,0x68e1134e},
 {0xb4,4,0x4913ae1a}, {0xb8,4,0x141ee086}, {0xbc,4,0x07b9d175},
 {0xc0,4,0x81cf470a}, {0xc4,4,0x4d78e262}, {0xc8,4,0xfbc3ffb0},
 {0xcc,4,0x236e2d73}, {0xd0,4,0xf3c3de59}, {0xd4,4,0x660c5247},
 {0xd8,4,0x5d7d3f45}, {0xdc,4,0xab8ae08b}, {0xe0,4,0x2545e583},
 {0xe4,4,0x6cf484f4}, {0xe8,64,0x2499bfda}, {0x128,128,0x3a5eda05}, {0x1a8,0,0xdfc82223}
};
static const uint32_t paint_tags[] = {0x4c9819e4,0xdecc8954,0x23135bc5,0xffc750b6,0xa56e42ec};
static const uint32_t paint_on[] = {500,0x56934941,0x1d7fadf4,0x8000,0x80000};
static const uint32_t paint_off[] = {0,0xb6eede09,0xafff8aa5,0,0};
#define NF (sizeof fields/sizeof *fields)
static int index_ok(const uint8_t *b, size_t n) {
    if (n<0x30 || n>16u*1024u*1024u || u32(b)!=0x01020304 || u32(b+4)!=1) return 0;
    uint32_t end=u32(b+8); return end>=0x30 && end<=n && !((end-0x28)%8);
}
static int array(const uint8_t *b,size_t n,uint32_t tag,size_t count,size_t stride,size_t *out) {
    if (!index_ok(b,n)) return -1;
    uint32_t end=u32(b+8), p=0; unsigned found=0;
    for (size_t o=0x28;o<end;o+=8) if(u32(b+o)==tag){p=u32(b+o+4);found++;}
    if (found!=1 || p<end || p>n || n-p<4 || u32(b+p)!=count || stride>(n-p-4)/count) return -1;
    size_t boundary=n,required=stride?count*stride:((count+31)/32)*4;
    for(size_t o=0x28;o<end;o+=8){uint32_t other=u32(b+o+4);if(u32(b+o)!=tag && other==p)return -1;if(other>p && other<boundary)boundary=other;}
    if(boundary<(size_t)p+4 || required>boundary-p-4)return -1;
    *out=(size_t)p+4; return 0;
}
static int layout(const uint8_t *m,size_t n,size_t locations[NF],size_t *refs,char *e,size_t c) {
    for(size_t i=0;i<NF;i++) {
        if(array(m,n,fields[i].tag,fields[i].stride?70:210,fields[i].stride,&locations[i]) || (!fields[i].stride && n-locations[i]<28))return fail(e,c,"Unsupported Mii save layout (field %08x).",fields[i].tag);
    }
    if(array(m,n,0x5e32adf4,70,4,refs))return fail(e,c,"Unsupported face-paint reference table.");
    for(unsigned i=0;i<70;i++) {
        const uint8_t *raw=m+locations[0]+i*156;
        if(u32(raw)!=152)return fail(e,c,"Invalid Mii record length.");
        uint32_t ref=u32(m+*refs+i*4);
        if(ref!=UINT32_MAX && ref>=72)return fail(e,c,"Invalid face-paint reference.");
    }
    // 所有會寫入的欄位都不能重疊，防止惡意索引把名字指向另一張表。
    // Writable fields must not overlap; a hostile index cannot point a name into another table.
    for(size_t i=0;i<NF;i++) {
        size_t lo=locations[i],hi=lo+(fields[i].stride?70*fields[i].stride:28);
        if(lo<*refs+280 && *refs<hi)return fail(e,c,"Overlapping save fields.");
        for(size_t j=0;j<i;j++)if(lo<locations[j]+(fields[j].stride?70*fields[j].stride:28) && locations[j]<hi)return fail(e,c,"Overlapping save fields.");
    }
    return 0;
}
int dm_mii_ltd_parse(const void *v,size_t n,dm_mii_ltd *out,char *e,size_t cap) {
    const uint8_t *b=v; if(!out || !b || n<436 || n>DM_MII_LTD_LIMIT)return fail(e,cap,"Invalid Mii file size.");
    memset(out,0,sizeof *out);
    if(b[0]!=3 || b[1]>1 || b[2]>1 || b[3])return fail(e,cap,"Only ShareMii .ltd version 3 is supported.");
    if(u32(b+4)!=152 || !utf16(b+24,11,1) || !utf16(b+0xe8,32,2) || !utf16(b+0x128,64,3))return fail(e,cap,"Invalid Mii record or name.");
    unsigned identity=0;for(size_t i=8;i<24;i++)identity|=b[i];if(!identity)return fail(e,cap,"The Mii identity is empty.");
    if(b[0x1a8]>1 || b[0x1a9]>1 || b[0x1aa]>1 || b[0x1ab])return fail(e,cap,"Invalid Mii preference flags.");
    for(size_t p=0xa0;p<=0xb0;p+=4)if(u32(b+p)>10)return fail(e,cap,"Invalid personality value.");
    for(size_t p=0xb4;p<=0xc4;p+=4)if(u32(b+p)>100)return fail(e,cap,"Invalid voice value.");
    if(u32(b+0x1ac)!=0xa3a3a3a3)return fail(e,cap,"Missing face-paint canvas marker.");
    size_t o=0x1b0,cn=0,un=0;
    if(u32(b+o)!=0xa4a4a4a4) {
        if(dm_mii_zstd_frame(b+o,n-o,262144,&cn))return fail(e,cap,"Invalid or unsupported face-paint canvas.");
        o+=cn;
    }
    if(o>n || n-o<4 || u32(b+o)!=0xa4a4a4a4)return fail(e,cap,"Missing face-paint texture marker.");
    o+=4;
    if(o<n && dm_mii_zstd_frame(b+o,n-o,131072,&un))return fail(e,cap,"Invalid or unsupported face-paint texture.");
    if(o+un!=n || (!!cn!=!!un) || !!cn!=b[1] || !!un!=b[2])return fail(e,cap,"Incomplete face paint or trailing data.");
    out->bytes=b;out->size=n;out->canvas=cn?b+0x1b0:NULL;out->canvas_size=cn;out->ugc=un?b+o:NULL;out->ugc_size=un;return 0;
}
int dm_mii_roster(const void *v,size_t n,dm_mii_slot out[70],char *e,size_t cap) {
    const uint8_t *m=v;size_t loc[NF],refs;if(!m||!out||layout(m,n,loc,&refs,e,cap))return -1;
    for(unsigned i=0;i<70;i++) {
        const uint8_t *raw=m+loc[0]+156*i,*name=m+loc[19]+64*i;int id=0;
        for(unsigned k=4;k<20;k++)id|=raw[k];
        out[i].initialized=id && utf16(name,32,2);
        memcpy(out[i].raw,raw,156);memcpy(out[i].name,name,64);
    }
    return 0;
}
int dm_mii_export_fixed(const void *v,size_t n,unsigned slot,uint8_t out[428],uint32_t *paint,char *e,size_t cap) {
    const uint8_t *m=v;size_t loc[NF],refs;dm_mii_slot roster[70];
    if(slot>=70)return fail(e,cap,"Invalid islander slot.");
    if(dm_mii_roster(v,n,roster,e,cap)||layout(m,n,loc,&refs,e,cap))return -1;
    if(!roster[slot].initialized)return fail(e,cap,"Create and save an islander in this slot first.");
    memset(out,0,428);put32(out,3);
    for(size_t i=0;i<NF;i++) {
        if(fields[i].stride)memcpy(out+fields[i].offset,m+loc[i]+slot*fields[i].stride,fields[i].stride);
        else {uint32_t value=0;for(unsigned bit=0;bit<3;bit++){unsigned at=slot*3+bit;value|=((m[loc[i]+at/8]>>(at%8))&1u)<<(bit*8);}put32(out+fields[i].offset,value);}
    }
    *paint=u32(m+refs+slot*4);out[1]=out[2]=*paint!=UINT32_MAX;return 0;
}
int dm_mii_apply(void *mv,size_t mn,void *pv,size_t pn,const dm_mii_ltd *ltd,unsigned slot,dm_mii_paint_plan *paint,char *e,size_t cap) {
    uint8_t *m=mv,*p=pv;size_t loc[NF],refs,pl[5];dm_mii_slot roster[70];dm_mii_ltd checked;
    if(!mv || !pv || !paint || !ltd || slot>=70)return fail(e,cap,"Invalid import target.");
    if(dm_mii_ltd_parse(ltd->bytes,ltd->size,&checked,e,cap))return -1;
    if(dm_mii_roster(m,mn,roster,e,cap)||layout(m,mn,loc,&refs,e,cap))return -1;
    if(!roster[slot].initialized)return fail(e,cap,"Create and save a placeholder islander first.");
    for(size_t i=0;i<5;i++)if(array(p,pn,paint_tags[i],72,4,&pl[i]))return fail(e,cap,"Unsupported Player save layout.");
    for(size_t i=0;i<5;i++)for(size_t j=0;j<i;j++)if(pl[i]<pl[j]+288 && pl[j]<pl[i]+288)return fail(e,cap,"Overlapping Player save fields.");
    uint32_t old=u32(m+refs+slot*4);int shared=0;
    for(unsigned i=0;i<70;i++)if(i!=slot && old!=UINT32_MAX && u32(m+refs+i*4)==old)shared=1;
    int chosen=-1;
    if(checked.canvas_size) {
        if(old<70&&!shared)chosen=(int)old;
        else for(unsigned k=0;k<70;k++) {
            int used=0;for(unsigned i=0;i<70;i++)used|=u32(m+refs+i*4)==k;
            if(!used && !u32(p+pl[0]+4*k) && !u32(p+pl[3]+4*k)){chosen=(int)k;break;}
        }
        if(chosen<0)return fail(e,cap,"No unused face-paint slot is available.");
    }
    // 所有驗證完成才寫入；保留關係、記憶、存檔進度與其他居民的資料。
    // Write only after validation; preserve relationships, memories, progress and other islanders.
    for(size_t i=0;i<NF;i++) {
        if(fields[i].stride)memcpy(m+loc[i]+slot*fields[i].stride,checked.bytes+fields[i].offset,fields[i].stride);
        else {uint32_t value=u32(checked.bytes+fields[i].offset);for(unsigned bit=0;bit<3;bit++){unsigned at=slot*3+bit;uint8_t mask=(uint8_t)(1u<<(at%8));m[loc[i]+at/8]=(uint8_t)((m[loc[i]+at/8]&~mask)|(((value>>(bit*8))&1u)<<(at%8)));}}
    }
    // 含臉部彩繪時，參考工具將原始資料的第 43 位元組設為 1；不把它臆測成 SDK 的其他欄位。
    // With face paint, the reference sets raw payload byte 43 to 1; do not infer another SDK field from its offset.
    if(checked.canvas_size)m[loc[0]+slot*156+43]=1;
    if(old<72&&!shared && (chosen<0 || (uint32_t)chosen!=old)) {
        for(size_t i=0;i<5;i++)put32(p+pl[i]+old*4,paint_off[i]);
    }
    if(chosen>=0)for(size_t i=0;i<5;i++)put32(p+pl[i]+(unsigned)chosen*4,paint_on[i] | (i==4?(unsigned)chosen:0));
    put32(m+refs+slot*4,chosen<0?UINT32_MAX:(uint32_t)chosen);
    paint->write_paint=chosen>=0;paint->paint_index=chosen>=0?(unsigned)chosen:0;return 0;
}
