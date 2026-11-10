// 合成存檔／.ltd 測試：不帶遊戲資料，檢查格式邊界與只寫入所選欄位。
// Synthetic save/.ltd tests: no game data; verify format bounds and selected-field-only writes.
#include "../Sources/dm_mii_codec.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <errno.h>
static int cases;
#define CHECK(x) do{cases++;if(!(x)){fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x);exit(1);}}while(0)
static uint32_t get32(const void *v){const unsigned char*p=v;return p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;}
static void put(void *v,uint32_t n){unsigned char*p=v;for(int i=0;i<4;i++)p[i]=(unsigned char)(n>>(i*8));}
static const uint32_t tags[]={0x881ca27a,0x43cd364f,0xcd8dbaf8,0x25b48224,0x607ba160,0x68e1134e,0x4913ae1a,0x141ee086,0x07b9d175,0x81cf470a,0x4d78e262,0xfbc3ffb0,0x236e2d73,0xf3c3de59,0x660c5247,0x5d7d3f45,0xab8ae08b,0x2545e583,0x6cf484f4,0x2499bfda,0x3a5eda05,0xdfc82223,0x5e32adf4,0x11111111};
static const uint32_t player_tags[]={0x4c9819e4,0xdecc8954,0x23135bc5,0xffc750b6,0xa56e42ec};
static unsigned char *mii,*player;static size_t mn,pn,loc[24],pl[5];
static void text(unsigned char *p,const char*s){while(*s){*p=(unsigned char)*s++;p+=2;}}
static void fixture(void){
 mn=0x28+24*8;for(unsigned i=0;i<24;i++){size_t n=i==0?70*156:i==19?70*64:i==20?70*128:i==21?28:70*4;mn+=4+n;}
 mii=calloc(1,mn);put(mii,0x01020304);put(mii+4,1);put(mii+8,0x28+24*8);size_t off=0x28+24*8;
 for(unsigned i=0;i<24;i++){put(mii+0x28+i*8,tags[i]);put(mii+0x2c+i*8,(uint32_t)off);put(mii+off,i==21?210:70);loc[i]=off+4;off+=4+(i==0?70*156:i==19?70*64:i==20?70*128:i==21?28:70*4);}
 for(unsigned i=0;i<70;i++){put(mii+loc[0]+i*156,152);put(mii+loc[22]+i*4,UINT32_MAX);}
 const char*names[]={"Placeholder","Avery","Sam","Casey"};
 for(unsigned i=0;i<4;i++){mii[loc[0]+i*156+4]=(unsigned char)(i+1);text(mii+loc[19]+i*64,names[i]);text(mii+loc[20]+i*128,names[i]);}
 memset(mii+loc[23],0x5a,280);
 pn=0x28+5*8+5*(4+72*4);player=calloc(1,pn);put(player,0x01020304);put(player+4,1);put(player+8,0x28+5*8);off=0x28+5*8;
 const uint32_t defaults[]={0,0xb6eede09,0xafff8aa5,0,0};
 for(unsigned i=0;i<5;i++){put(player+0x28+i*8,player_tags[i]);put(player+0x2c+i*8,(uint32_t)off);put(player+off,72);pl[i]=off+4;for(unsigned j=0;j<72;j++)put(player+pl[i]+j*4,defaults[i]);off+=4+72*4;}
}
static const unsigned char canvas[]={0x28,0xb5,0x2f,0xfd,0xa0,0,0,4,0,2,0,0x10,0,3,0,0x10,0};
static const unsigned char texture[]={0x28,0xb5,0x2f,0xfd,0xa0,0,0,2,0,3,0,0x10,0};
static unsigned char *sample(size_t *n,int paint){
 unsigned char b[428];uint32_t id;char e[256];CHECK(!dm_mii_export_fixed(mii,mn,0,b,&id,e,sizeof e));text(b+0xe8,"Alex");text(b+0x128,"Alex");b[0xe8+8]=0;b[0xe8+9]=0;b[0x128+8]=0;b[0x128+9]=0;
 *n=436+(paint?sizeof canvas+sizeof texture:0);unsigned char*out=calloc(1,*n);memcpy(out,b,428);out[1]=out[2]=(unsigned char)paint;put(out+428,0xa3a3a3a3);size_t p=432;if(paint){memcpy(out+p,canvas,sizeof canvas);p+=sizeof canvas;}put(out+p,0xa4a4a4a4);p+=4;if(paint)memcpy(out+p,texture,sizeof texture);return out;
}
static void emit(const char*dir){char p[4096];mkdir(dir,0700);snprintf(p,sizeof p,"%s/.mii-test-workspace",dir);FILE*f=fopen(p,"wb");CHECK(f);fclose(f);snprintf(p,sizeof p,"%s/save",dir);mkdir(p,0700);snprintf(p,sizeof p,"%s/save/Mii.sav",dir);f=fopen(p,"wb");CHECK(f&&fwrite(mii,1,mn,f)==mn);fclose(f);snprintf(p,sizeof p,"%s/save/Player.sav",dir);f=fopen(p,"wb");CHECK(f&&fwrite(player,1,pn,f)==pn);fclose(f);snprintf(p,sizeof p,"%s/save/Map.sav",dir);f=fopen(p,"wb");CHECK(f);fputs("synthetic map; no game data",f);fclose(f);size_t n;unsigned char*b=sample(&n,0);snprintf(p,sizeof p,"%s/Alex.ltd",dir);f=fopen(p,"wb");CHECK(f&&fwrite(b,1,n,f)==n);fclose(f);free(b);b=sample(&n,1);snprintf(p,sizeof p,"%s/Alex-Facepaint.ltd",dir);f=fopen(p,"wb");CHECK(f&&fwrite(b,1,n,f)==n);fclose(f);free(b);}
int main(int argc,char**argv){fixture();if(argc==3&&!strcmp(argv[1],"--emit-fixture")){emit(argv[2]);return 0;}
 char e[256]={0};dm_mii_slot slots[70];CHECK(!dm_mii_roster(mii,mn,slots,e,sizeof e));CHECK(slots[0].initialized&&slots[3].initialized&&!slots[4].initialized);
 size_t n;unsigned char*b=sample(&n,0);dm_mii_ltd ltd;CHECK(!dm_mii_ltd_parse(b,n,&ltd,e,sizeof e));CHECK(!ltd.canvas_size&&!ltd.ugc_size);
 for(size_t size=0;size<n;size++)CHECK(dm_mii_ltd_parse(b,size,&ltd,e,sizeof e));
 unsigned char*mut=malloc(n);memcpy(mut,b,n);mut[0]=4;CHECK(dm_mii_ltd_parse(mut,n,&ltd,e,sizeof e));memcpy(mut,b,n);mut[1]=1;CHECK(dm_mii_ltd_parse(mut,n,&ltd,e,sizeof e));memcpy(mut,b,n);memset(mut+0xe8,'Z',64);CHECK(dm_mii_ltd_parse(mut,n,&ltd,e,sizeof e));memcpy(mut,b,n);mut[0xe8]=0;mut[0xe9]=0xd8;mut[0xea]='X';mut[0xeb]=0;CHECK(dm_mii_ltd_parse(mut,n,&ltd,e,sizeof e));
 memcpy(mut,b,n);mut[0x128]=8;mut[0x129]=0;CHECK(!dm_mii_ltd_parse(mut,n,&ltd,e,sizeof e));
 CHECK(!dm_mii_ltd_parse(b,n,&ltd,e,sizeof e));dm_mii_paint_plan plan;unsigned char*before=malloc(mn),*pb=malloc(pn);memcpy(before,mii,mn);memcpy(pb,player,pn);
 CHECK(dm_mii_apply(mii,mn,player,pn,&ltd,70,&plan,e,sizeof e));CHECK(!memcmp(before,mii,mn)&&!memcmp(pb,player,pn));CHECK(dm_mii_apply(mii,mn,player,pn,&ltd,4,&plan,e,sizeof e));CHECK(!memcmp(before,mii,mn));
 CHECK(!dm_mii_apply(mii,mn,player,pn,&ltd,1,&plan,e,sizeof e));CHECK(!memcmp(mii+loc[23],before+loc[23],280));CHECK(!memcmp(mii+loc[0],before+loc[0],156));CHECK(!memcmp(mii+loc[0]+2*156,before+loc[0]+2*156,68*156));CHECK(!memcmp(player,pb,pn));
 memcpy(mii,before,mn);put(mii+0x2c,1);CHECK(dm_mii_roster(mii,mn,slots,e,sizeof e));memcpy(mii,before,mn);
 unsigned char*paint=sample(&n,1);CHECK(!dm_mii_ltd_parse(paint,n,&ltd,e,sizeof e));CHECK(ltd.canvas_size==sizeof canvas&&ltd.ugc_size==sizeof texture);
 CHECK(!dm_mii_apply(mii,mn,player,pn,&ltd,0,&plan,e,sizeof e));CHECK(plan.write_paint&&plan.paint_index==0);CHECK(get32(mii+loc[22])==0);CHECK(get32(player+pl[0])==500);CHECK(mii[loc[0]+43]==1);
 unsigned char fixed[428];uint32_t id;CHECK(!dm_mii_export_fixed(mii,mn,0,fixed,&id,e,sizeof e));CHECK(id==0&&fixed[1]==1&&fixed[2]==1);
 unsigned char*plain=sample(&n,0);plain[1]=plain[2]=0;CHECK(!dm_mii_ltd_parse(plain,n,&ltd,e,sizeof e));CHECK(!dm_mii_apply(mii,mn,player,pn,&ltd,0,&plan,e,sizeof e));CHECK(get32(mii+loc[22])==UINT32_MAX);CHECK(get32(player+pl[0])==0&&get32(player+pl[4])==0);
 size_t painted_size;free(paint);paint=sample(&painted_size,1);CHECK(!dm_mii_ltd_parse(paint,painted_size,&ltd,e,sizeof e));for(unsigned i=0;i<70;i++){put(player+pl[0]+i*4,500);put(player+pl[3]+i*4,0x8000);}memcpy(before,mii,mn);memcpy(pb,player,pn);CHECK(dm_mii_apply(mii,mn,player,pn,&ltd,0,&plan,e,sizeof e));CHECK(!memcmp(before,mii,mn)&&!memcmp(pb,player,pn));
 for(size_t i=432;i<painted_size;i++){unsigned char old=paint[i];paint[i]^=255;dm_mii_ltd_parse(paint,painted_size,&ltd,e,sizeof e);paint[i]=old;}
 CHECK(dm_mii_apply(NULL,mn,player,pn,&ltd,0,&plan,e,sizeof e));
 free(mii);free(player);free(before);free(pb);free(b);free(mut);free(paint);free(plain);printf("MII_CODEC cases=%d passed; synthetic files only\n",cases);return 0;}
