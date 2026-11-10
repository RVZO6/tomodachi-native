// 合成資料測試；不接觸遊戲、存檔或裝置。
// Synthetic tests only; no game, save, or device access.
#include "../Sources/dm_mii_new.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned cases;
#define CHECK(x) do { cases++; assert(x); } while (0)
static void put32(uint8_t *p, uint32_t v) { for (unsigned i=0;i<4;i++) p[i]=(uint8_t)(v>>(8*i)); }
static uint32_t get32(const uint8_t *p) { return p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24; }
static void sample(uint8_t b[436]) {
    memset(b,0,436); b[0]=3; put32(b+4,152);
    for (unsigned i=8;i<24;i++) b[i]=(uint8_t)i;
    for (unsigned i=0;i<5;i++) put32(b+0xa0+4*i,i+1);
    for (unsigned i=0;i<5;i++) put32(b+0xb4+4*i,20+i);
    // 未知純量也必須逐位元保留；不能補上猜測的預設值。
    // Preserve unknown scalars bit for bit; never supply guessed defaults.
    for (unsigned i=10;i<18;i++) put32(b+0xa0+4*i,0xfedc0000+i);
    b[0xe8]='N'; b[0x128]='P'; b[0x1a8]=1; b[0x1aa]=1;
    put32(b+428,0xa3a3a3a3); put32(b+432,0xa4a4a4a4);
}
int main(void) {
    uint8_t b[436]; sample(b); char e[256]; dm_mii_slot roster[70]={0};
    dm_mii_input *input=dm_mii_input_open(b,sizeof b,e,sizeof e); CHECK(input);
    const dm_mii_ltd *view=dm_mii_input_view(input); CHECK(view && view->bytes!=b);
    b[8]^=255; CHECK(view->bytes[8]==8); b[8]^=255;
    dm_mii_new_plan plan; CHECK(!dm_mii_new_plan_make(input,roster,&plan,e,sizeof e));
    CHECK(!memcmp(plan.appearance,b+8,152));
    for (unsigned i=0;i<18;i++) CHECK(plan.scalar[i]==get32(b+0xa0+4*i));
    CHECK(!memcmp(plan.name,b+0xe8,64)); CHECK(!memcmp(plan.pronounced,b+0x128,128));
    CHECK(!memcmp(plan.preferences,b+0x1a8,3)); CHECK(!memcmp(view->bytes,b,sizeof b));
    CHECK(plan.gaps==63); CHECK(!dm_mii_new_can_execute(&plan)); CHECK(!dm_mii_new_can_execute(NULL));
    plan.gaps=0; CHECK(!dm_mii_new_can_execute(&plan));
    dm_mii_new_plan before=plan;
    CHECK(dm_mii_new_plan_make(NULL,roster,&plan,e,sizeof e)); CHECK(!memcmp(&before,&plan,sizeof plan));
    CHECK(dm_mii_new_plan_make(input,NULL,&plan,NULL,0)); CHECK(!memcmp(&before,&plan,sizeof plan));
    CHECK(dm_mii_new_plan_make(input,roster,NULL,e,sizeof e));
    for (unsigned slot=0;slot<70;slot++) {
        memset(roster,0,sizeof roster); memcpy(roster[slot].raw+4,b+8,16);
        // 沒有有效名字的識別碼仍可能屬於既有居民。
        // An identity without a valid name can still belong to an existing islander.
        CHECK(dm_mii_new_plan_make(input,roster,&plan,e,sizeof e)); CHECK(!memcmp(&before,&plan,sizeof plan));
        roster[slot].initialized=1;
        CHECK(dm_mii_new_plan_make(input,roster,&plan,e,sizeof e)); CHECK(!memcmp(&before,&plan,sizeof plan));
    }
    for (unsigned i=0;i<70;i++) { roster[i].initialized=1; memset(roster[i].raw+4,0x66,16); }
    CHECK(dm_mii_new_plan_make(input,roster,&plan,e,sizeof e)); CHECK(!memcmp(&before,&plan,sizeof plan));
    roster[69].initialized=0; CHECK(!dm_mii_new_plan_make(input,roster,&plan,e,sizeof e));
    dm_mii_input_cleanup(&input); CHECK(!input); dm_mii_input_cleanup(&input); dm_mii_input_cleanup(NULL);
    CHECK(!dm_mii_input_view(NULL)); dm_mii_input_close(NULL);
    for (unsigned n=0;n<436;n++) CHECK(!dm_mii_input_open(b,n,e,sizeof e));
    CHECK(!dm_mii_input_open(b,DM_MII_LTD_LIMIT+1u,e,sizeof e));
    CHECK(!dm_mii_input_open(NULL,436,e,sizeof e));
    put32(b+0xa0,11); CHECK(!dm_mii_input_open(b,sizeof b,e,sizeof e));
    sample(b); put32(b+0xb4,101); CHECK(!dm_mii_input_open(b,sizeof b,e,sizeof e));
    sample(b); b[0]=4; CHECK(!dm_mii_input_open(b,sizeof b,e,sizeof e)); sample(b);
    // 合成的壓縮零值影像；不是遊戲資源。
    // Synthetic compressed zero images; not game resources.
    const uint8_t c[]={0x28,0xb5,0x2f,0xfd,0xa0,0,0,4,0,2,0,0x10,0,3,0,0x10,0};
    const uint8_t t[]={0x28,0xb5,0x2f,0xfd,0xa0,0,0,2,0,3,0,0x10,0};
    uint8_t painted[436+sizeof c+sizeof t]; memcpy(painted,b,432); painted[1]=painted[2]=1;
    memcpy(painted+432,c,sizeof c); put32(painted+432+sizeof c,0xa4a4a4a4); memcpy(painted+436+sizeof c,t,sizeof t);
    input=dm_mii_input_open(painted,sizeof painted,e,sizeof e); CHECK(input); memset(roster,0,sizeof roster);
    memset(painted,0,sizeof painted);
    CHECK(!dm_mii_new_plan_make(input,roster,&plan,e,sizeof e)); CHECK(plan.gaps&DM_MII_NEW_PAINT);
    CHECK(!dm_mii_new_can_execute(&plan)); view=dm_mii_input_view(input);
    CHECK(view->canvas_size==sizeof c && view->ugc_size==sizeof t);
    CHECK(!memcmp(view->canvas,c,sizeof c)); CHECK(!memcmp(view->ugc,t,sizeof t));
    dm_mii_input_close(input);
    // 空白存檔不能經由新的擁有者入口變成建立路徑。
    // The owning replacement entry point cannot turn a blank save into a creation path.
    uint8_t mii[64]={0},player[64]={0},saved[64]={0}; dm_mii_paint_plan paint={0};
    input=dm_mii_input_open(b,sizeof b,e,sizeof e); CHECK(input);
    CHECK(dm_mii_input_replace(input,mii,sizeof mii,player,sizeof player,0,&paint,e,sizeof e));
    CHECK(!memcmp(mii,saved,sizeof mii) && !memcmp(player,saved,sizeof player));
    CHECK(dm_mii_input_replace(NULL,mii,sizeof mii,player,sizeof player,0,&paint,NULL,0));
    dm_mii_input_close(input);
    printf("MII_NEW_PREFLIGHT cases=%u passed; synthetic only; creation disabled\n",cases);
}
