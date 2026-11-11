// Mii 匯入不在遊戲執行中的存檔上寫入：先排程，啓動前編輯最新的已提交版並原子交換。
// Never edit a live game save: queue the import, then edit the latest committed copy and swap it atomically before boot.
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#include <sys/clonefile.h>
#include <sys/stat.h>
#include <errno.h>
#include <stdio.h>
#include <unistd.h>
#include "duo_mii.h"
#include "duo_save_store.h"
#include "dm_mii_codec.h"
#include "dm_mii_input.h"

static NSFileManager *fm(void) { return NSFileManager.defaultManager; }
static NSString *save(void) { return [duo_save_documents() stringByAppendingPathComponent:@"save"]; }
static NSString *jobs(void) { return [duo_save_documents() stringByAppendingPathComponent:@".mii-imports"]; }
static BOOL error(NSString **out, NSString *s) { if(out)*out=s; return NO; }
static NSString *hash(NSData *d) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(d.bytes,(CC_LONG)d.length,digest);
    NSMutableString *s=[NSMutableString string];for(unsigned i=0;i<sizeof digest;i++)[s appendFormat:@"%02x",digest[i]];return s;
}
static NSString *file_hash(NSString *path) {
    NSInputStream *s=[NSInputStream inputStreamWithFileAtPath:path];[s open];CC_SHA256_CTX ctx;CC_SHA256_Init(&ctx);uint8_t bytes[16384];NSInteger n;
    while((n=[s read:bytes maxLength:sizeof bytes])>0)CC_SHA256_Update(&ctx,bytes,(CC_LONG)n);
    BOOL ok=n==0;[s close];if(!ok)return nil;unsigned char digest[32];CC_SHA256_Final(digest,&ctx);
    NSMutableString *out=[NSMutableString string];for(unsigned i=0;i<32;i++)[out appendFormat:@"%02x",digest[i]];return out;
}
static BOOL regular(NSString *p) { NSDictionary *a=[fm() attributesOfItemAtPath:p error:nil];return [a[NSFileType] isEqual:NSFileTypeRegular]; }
static BOOL tree_safe(NSString *dir) {
    NSDictionary *a=[fm() attributesOfItemAtPath:dir error:nil];if(![a[NSFileType] isEqual:NSFileTypeDirectory])return NO;
    NSDirectoryEnumerator *e=[fm() enumeratorAtPath:dir];if(!e)return NO;
    for(NSString *rel in e){NSString *p=[dir stringByAppendingPathComponent:rel];NSString *type=[fm() attributesOfItemAtPath:p error:nil][NSFileType];if(![type isEqual:NSFileTypeRegular]&&![type isEqual:NSFileTypeDirectory])return NO;}
    return YES;
}
static NSDictionary *tree_hashes(NSString *dir) {
    if(!tree_safe(dir))return nil;NSMutableDictionary *out=[NSMutableDictionary dictionary];
    for(NSString *rel in [fm() enumeratorAtPath:dir]){NSString *p=[dir stringByAppendingPathComponent:rel];if(regular(p)){NSString *h=file_hash(p);if(!h)return nil;out[rel]=h;}}
    return out;
}
static BOOL copy_tree(NSString *from,NSString *to) { return tree_safe(from)&&(!clonefile(from.fileSystemRepresentation,to.fileSystemRepresentation,0)||[fm() copyItemAtPath:from toPath:to error:nil]); }
static NSData *bounded(NSString *path,NSUInteger limit,NSString **out) {
    if(!regular(path)){error(out,@"The file is missing or is not a regular file.");return nil;}
    NSInputStream *s=[NSInputStream inputStreamWithFileAtPath:path];[s open];NSMutableData *d=[NSMutableData data];uint8_t bytes[16384];NSInteger n=0;
    while(d.length<=limit && (n=[s read:bytes maxLength:MIN(sizeof bytes,limit+1-d.length)])>0)[d appendBytes:bytes length:(NSUInteger)n];
    [s close];if(n<0||d.length>limit){error(out,@"The file could not be read or is too large.");return nil;}return d;
}
// 擁有者必須存活到所有檢視使用完畢；每個呼叫範圍自動清理。
// Keep the owner alive through all view use; each caller scope performs automatic cleanup.
static BOOL parse(NSData *data,dm_mii_input **owner,dm_mii_ltd *ltd,NSString **out) {
    char e[256]={0};*owner=data?dm_mii_input_open(data.bytes,data.length,e,sizeof e):NULL;
    if(!*owner)return error(out,e[0]?@(e):@"The Mii file is invalid.");
    *ltd=*dm_mii_input_view(*owner);return YES;
}
static NSString *name_bytes(const uint8_t *bytes,size_t n) {
    size_t len=0;while(len+1<n&&(bytes[len]||bytes[len+1]))len+=2;NSString *s=[[NSString alloc] initWithBytes:bytes length:len encoding:NSUTF16LittleEndianStringEncoding]?:@"";s=[[s componentsSeparatedByCharactersInSet:NSCharacterSet.controlCharacterSet] componentsJoinedByString:@""];return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length?s:@"Mii";
}
static NSString *fingerprint(const dm_mii_slot *s) { NSMutableData *d=[NSMutableData dataWithBytes:s->raw length:156];[d appendBytes:s->name length:64];return hash(d); }
static NSString *snapshot(NSString **out) {
    NSString *dir=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"mii-snapshot-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    if(duo_save_snapshot_to(dir)||!tree_safe(dir)){[fm() removeItemAtPath:dir error:nil];error(out,@"No readable saved island is available. Save the game and try again.");return nil;}return dir;
}
static BOOL roster_data(NSString *dir,NSData **mii,NSData **player,dm_mii_slot slots[70],NSString **out) {
    NSData *m=bounded([dir stringByAppendingPathComponent:@"Mii.sav"],16u*1024u*1024u,out);
    NSData *p=bounded([dir stringByAppendingPathComponent:@"Player.sav"],16u*1024u*1024u,out);if(!m||!p)return NO;
    char e[256]={0};if(dm_mii_roster(m.bytes,m.length,slots,e,sizeof e))return error(out,@(e));if(mii)*mii=m;if(player)*player=p;return YES;
}
NSArray<NSDictionary *> *duo_mii_roster(NSString **out) {
    NSString *dir=snapshot(out);if(!dir)return nil;dm_mii_slot slots[70];BOOL ok=roster_data(dir,NULL,NULL,slots,out);NSMutableArray *list=[NSMutableArray array];
    if(ok)for(unsigned i=0;i<70;i++)if(slots[i].initialized)[list addObject:@{@"slot":@(i+1),@"name":name_bytes(slots[i].name,64),@"fingerprint":fingerprint(&slots[i])}];
    [fm() removeItemAtPath:dir error:nil];return ok?list:nil;
}
NSDictionary *duo_mii_read_file(NSURL *url,NSString **out) {
    BOOL scoped=[url startAccessingSecurityScopedResource];__block NSData *data=nil;__block NSString *why=nil;NSError *coord=nil;
    [[[NSFileCoordinator alloc] initWithFilePresenter:nil] coordinateReadingItemAtURL:url options:NSFileCoordinatorReadingWithoutChanges error:&coord byAccessor:^(NSURL *u){data=bounded(u.path,DM_MII_LTD_LIMIT,&why);}];
    if(scoped)[url stopAccessingSecurityScopedResource];if(!data){error(out,why?:coord.localizedDescription?:@"The selected file is not available.");return nil;}
    data=[data copy];dm_mii_input *owner __attribute__((cleanup(dm_mii_input_cleanup)))=NULL;dm_mii_ltd ltd;if(!parse(data,&owner,&ltd,out))return nil;
    return @{@"bytes":data,@"filename":url.lastPathComponent?:@"Mii.ltd",@"name":name_bytes(ltd.bytes+0xe8,64),@"sha256":hash(data)};
}
static NSString *job_path(NSString *action) {
    if(![action hasPrefix:@"mii:"])return nil;NSString *token=[action substringFromIndex:4];NSUUID *u=[[NSUUID alloc] initWithUUIDString:token];
    return u && token.length==36?[jobs() stringByAppendingPathComponent:u.UUIDString]:nil;
}
// 準備過交換的工作含復原資料；只有確定完成後才可清除，取消未套用的工作則可直接刪暫存。
// A prepared swap job contains recovery data: remove it only after verified completion; a queued, unapplied job is disposable.
void duo_mii_discard_pending(NSString *action) {
    NSString *p=job_path(action);if(!p)return;
    NSData *data=bounded([p stringByAppendingPathComponent:@"plan.plist"],65536,nil);
    id plan=data?[NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:nil]:nil;
    NSString *phase=[plan isKindOfClass:NSDictionary.class]?plan[@"phase"]:nil;
    if([fm() fileExistsAtPath:[p stringByAppendingPathComponent:@"save.prepared"]] && ![phase isEqual:@"completed"] && ![phase isEqual:@"queued"])return;
    [fm() removeItemAtPath:p error:nil];
}
static BOOL write_plan(NSDictionary *plan,NSString *path) {
    NSData *d=[NSPropertyListSerialization dataWithPropertyList:plan format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    return d && [d writeToFile:[path stringByAppendingPathComponent:@"plan.plist"] options:NSDataWritingAtomic error:nil];
}
static BOOL target_ok(NSDictionary *target,dm_mii_slot slots[70],unsigned *slot,NSString **out) {
    id n=target[@"slot"],h=target[@"fingerprint"];if(![n isKindOfClass:NSNumber.class]||![h isKindOfClass:NSString.class])return error(out,@"Choose an islander first.");
    NSInteger value=[n integerValue];if(value<1||value>70||!slots[value-1].initialized)return error(out,@"That islander is not saved yet. Save in the game, then try again.");
    if(![fingerprint(&slots[value-1]) isEqual:h])return error(out,@"The selected Mii has changed. Reopen the importer and select it again.");*slot=(unsigned)value-1;return YES;
}
BOOL duo_mii_queue(NSDictionary *input,NSDictionary *target,NSString **out) {
    if(![input isKindOfClass:NSDictionary.class]||![target isKindOfClass:NSDictionary.class])return error(out,@"Choose a file and an islander first.");
    if(duo_save_pending())return error(out,@"Another save change is already queued. Cancel it in Save Data first.");
    NSData *data=input[@"bytes"];if(![data isKindOfClass:NSData.class])return error(out,@"Choose a Mii file first.");dm_mii_input *owner __attribute__((cleanup(dm_mii_input_cleanup)))=NULL;dm_mii_ltd ltd;if(!parse(data,&owner,&ltd,out))return NO;
    data=[NSData dataWithBytes:ltd.bytes length:ltd.size];
    NSString *snap=snapshot(out);if(!snap)return NO;dm_mii_slot slots[70];NSData *m=nil,*p=nil;unsigned slot=0;BOOL ok=roster_data(snap,&m,&p,slots,out)&&target_ok(target,slots,&slot,out);
    if(ok){NSMutableData *mc=[m mutableCopy],*pc=[p mutableCopy];dm_mii_paint_plan paint;char e[256]={0};if(dm_mii_input_replace(owner,mc.mutableBytes,mc.length,pc.mutableBytes,pc.length,slot,&paint,e,sizeof e))ok=error(out,@(e));}
    [fm() removeItemAtPath:snap error:nil];if(!ok)return NO;
    NSString *token=NSUUID.UUID.UUIDString,*dir=[jobs() stringByAppendingPathComponent:token];
    if([fm() fileExistsAtPath:jobs()]&&!tree_safe(jobs()))return error(out,@"The Mii import folder is not safe to use.");
    if(![fm() createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil])return error(out,@"The import could not be saved. Check free storage.");
    NSDictionary *plan=@{@"version":@1,@"slot":@(slot+1),@"fingerprint":target[@"fingerprint"],@"sha256":hash(data),@"name":name_bytes(ltd.bytes+0xe8,64),@"phase":@"queued"};
    if(![data writeToFile:[dir stringByAppendingPathComponent:@"incoming.ltd"] options:NSDataWritingAtomic error:nil]||!write_plan(plan,dir)){[fm() removeItemAtPath:dir error:nil];return error(out,@"The import could not be saved. The island was not changed.");}
    duo_save_set_pending([@"mii:" stringByAppendingString:token]);return YES;
}
static NSString *paint_path(unsigned index,BOOL canvas) { return [NSString stringWithFormat:@"Ugc/UgcFacePaint%03u.%@.zs",index,canvas?@"canvas":@"ugctex"]; }
NSURL *duo_mii_export(NSDictionary *target,NSString **out) {
    NSString *snap=snapshot(out);if(!snap)return nil;NSData *m=nil;dm_mii_slot slots[70];unsigned slot=0;uint8_t fixed[428];uint32_t paint=UINT32_MAX;char e[256]={0};
    BOOL ok=roster_data(snap,&m,NULL,slots,out)&&target_ok(target,slots,&slot,out);if(ok&&dm_mii_export_fixed(m.bytes,m.length,slot,fixed,&paint,e,sizeof e))ok=error(out,@(e));
    NSMutableData *data=[NSMutableData dataWithBytes:fixed length:ok?sizeof fixed:0];uint32_t marker=0xa3a3a3a3;[data appendBytes:&marker length:4];
    if(ok&&paint!=UINT32_MAX){NSData *d=bounded([snap stringByAppendingPathComponent:paint_path(paint,YES)],DM_MII_LTD_LIMIT,out);if(d)[data appendData:d];else ok=NO;}
    marker=0xa4a4a4a4;[data appendBytes:&marker length:4];
    if(ok&&paint!=UINT32_MAX){NSData *d=bounded([snap stringByAppendingPathComponent:paint_path(paint,NO)],DM_MII_LTD_LIMIT,out);if(d)[data appendData:d];else ok=NO;}
    [fm() removeItemAtPath:snap error:nil];dm_mii_input *owner __attribute__((cleanup(dm_mii_input_cleanup)))=NULL;dm_mii_ltd checked;if(ok)ok=parse(data,&owner,&checked,out);if(!ok)return nil;
    NSString *dir=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"mii-export-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    if(![fm() createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil]){error(out,@"The export could not be saved.");return nil;}
    NSString *name=[name_bytes(checked.bytes+0xe8,64) stringByReplacingOccurrencesOfString:@"/" withString:@"-"];name=[name stringByReplacingOccurrencesOfString:@":" withString:@"-"];
    NSURL *url=[NSURL fileURLWithPath:[dir stringByAppendingPathComponent:[name stringByAppendingString:@".ltd"]]];
    if(![data writeToURL:url options:NSDataWritingAtomic error:nil]){[fm() removeItemAtPath:dir error:nil];error(out,@"The export could not be saved.");return nil;}return url;
}
static BOOL output_matches(NSDictionary *expected,NSString *dir) {
    if(![expected isKindOfClass:NSDictionary.class]||expected.count<2||expected.count>4||!tree_safe(dir))return NO;
    for(NSString *rel in expected){if(![rel isKindOfClass:NSString.class])return NO;BOOL allowed=[rel isEqual:@"Mii.sav"]||[rel isEqual:@"Player.sav"];
        if(!allowed){NSRegularExpression *r=[NSRegularExpression regularExpressionWithPattern:@"^Ugc/UgcFacePaint[0-9]{3}\\.(canvas|ugctex)\\.zs$" options:0 error:nil];allowed=[r numberOfMatchesInString:rel options:0 range:NSMakeRange(0,rel.length)]==1;}
        if(!allowed||![expected[rel] isKindOfClass:NSString.class]||![file_hash([dir stringByAppendingPathComponent:rel]) isEqual:expected[rel]])return NO;
    }
    return expected[@"Mii.sav"]&&expected[@"Player.sav"];
}
static void result(NSString *message,BOOL failed) { [duo_save_preferences() setObject:message forKey:@"MiiImportResult"];if(failed)duo_save_note_failure(@"mii");[duo_save_preferences() synchronize]; }
NSString *duo_mii_take_result(void) { NSString *s=[duo_save_preferences() stringForKey:@"MiiImportResult"];[duo_save_preferences() removeObjectForKey:@"MiiImportResult"];return s; }
static void interrupt_test(const char *phase) {
#ifdef DM_MII_TEST
    const char *p=getenv("DM_MII_TEST_INTERRUPT");if(p&&!strcmp(p,phase))_exit(77);
#else
    (void)phase;
#endif
}
BOOL duo_mii_apply_pending(NSString *action) {
    if(![action hasPrefix:@"mii:"])return NO;
    NSString *job=job_path(action),*why=nil;NSMutableDictionary *plan=nil;BOOL swapped=NO,applied=NO;NSString *stage=job?[job stringByAppendingPathComponent:@"save.prepared"]:nil;
    {
    dm_mii_input *owner __attribute__((cleanup(dm_mii_input_cleanup)))=NULL;
    if(!job||!tree_safe(job)){why=@"The queued Mii import is missing or invalid.";goto finish;}
    NSData *pd=bounded([job stringByAppendingPathComponent:@"plan.plist"],65536,&why);if(!pd)goto finish;
    id value=[NSPropertyListSerialization propertyListWithData:pd options:NSPropertyListMutableContainers format:NULL error:nil];
    if(![value isKindOfClass:NSMutableDictionary.class]||![value[@"version"] isEqual:@1]){why=@"The import plan is invalid.";goto finish;}plan=value;
    // 交換後被殺：確認輸出已在正式存檔，不能再把同一次匯入重做一遍。
    // Killed after the swap: recognize the installed output instead of applying the same import twice.
    if([plan[@"phase"] isEqual:@"prepared"]&&output_matches(plan[@"outputs"],save())){
        NSString *name=plan[@"backup"];NSDictionary *expected=plan[@"backupHashes"];
        if(![name isKindOfClass:NSString.class]||![name isEqual:name.lastPathComponent]||![expected isKindOfClass:NSDictionary.class]||![expected isEqual:tree_hashes([[duo_save_documents() stringByAppendingPathComponent:@"Backups"] stringByAppendingPathComponent:name])]){why=@"The import was installed, but its backup could not be verified. Recovery data has been kept.";goto finish;}
        applied=YES;goto finish;
    }
    NSData *data=bounded([job stringByAppendingPathComponent:@"incoming.ltd"],DM_MII_LTD_LIMIT,&why);dm_mii_ltd ltd;
    if(!data||![hash(data) isEqual:plan[@"sha256"]]||!parse(data,&owner,&ltd,&why)){if(!why)why=@"The queued Mii file changed. Import it again.";goto finish;}
    NSDictionary *before=tree_hashes(save());if(!before){why=@"The current island cannot be read safely.";goto finish;}
    [fm() removeItemAtPath:stage error:nil];if(!copy_tree(save(),stage)){why=@"The island could not be copied. Check free storage.";goto finish;}
    NSData *m=nil,*p=nil;dm_mii_slot slots[70];unsigned slot=0;
    if(!roster_data(stage,&m,&p,slots,&why)||!target_ok(plan,slots,&slot,&why))goto finish;
    NSMutableData *mc=[m mutableCopy],*pc=[p mutableCopy];dm_mii_paint_plan paint;char e[256]={0};
    if(dm_mii_input_replace(owner,mc.mutableBytes,mc.length,pc.mutableBytes,pc.length,slot,&paint,e,sizeof e)){why=@(e);goto finish;}
    if(![mc writeToFile:[stage stringByAppendingPathComponent:@"Mii.sav"] options:NSDataWritingAtomic error:nil]||![pc writeToFile:[stage stringByAppendingPathComponent:@"Player.sav"] options:NSDataWritingAtomic error:nil]){why=@"The edited save could not be written.";goto finish;}
    NSMutableDictionary *outputs=[NSMutableDictionary dictionaryWithDictionary:@{@"Mii.sav":hash(mc),@"Player.sav":hash(pc)}];
    if(paint.write_paint){NSString *ugc=[stage stringByAppendingPathComponent:@"Ugc"];if(![fm() createDirectoryAtPath:ugc withIntermediateDirectories:YES attributes:nil error:nil]){why=@"Face paint could not be saved.";goto finish;}
        NSData *canvas=[NSData dataWithBytes:ltd.canvas length:ltd.canvas_size],*texture=[NSData dataWithBytes:ltd.ugc length:ltd.ugc_size];
        NSString *a=paint_path(paint.paint_index,YES),*b=paint_path(paint.paint_index,NO);
        if(![canvas writeToFile:[stage stringByAppendingPathComponent:a] options:NSDataWritingAtomic error:nil]||![texture writeToFile:[stage stringByAppendingPathComponent:b] options:NSDataWritingAtomic error:nil]){why=@"Face paint could not be written.";goto finish;}outputs[a]=hash(canvas);outputs[b]=hash(texture);
    }
    if(!output_matches(outputs,stage)||![before isEqual:tree_hashes(save())]){why=@"The save changed during preparation. Nothing was imported.";goto finish;}
    int backup_error=0;NSString *backup=duo_backup_before_mii(&backup_error);
    if(!backup||![before isEqual:tree_hashes([[duo_save_documents() stringByAppendingPathComponent:@"Backups"] stringByAppendingPathComponent:backup])]){why=@"A verified backup could not be made. Nothing was imported.";goto finish;}
    plan[@"phase"]=@"prepared";plan[@"outputs"]=outputs;plan[@"backup"]=backup;plan[@"backupHashes"]=before;
    if(!write_plan(plan,job)){why=@"The import journal could not be saved. Nothing was imported.";goto finish;}
    interrupt_test("after-prepare");
    if(renamex_np(save().fileSystemRepresentation,stage.fileSystemRepresentation,RENAME_SWAP)){why=@"The save could not be installed atomically. The original island is unchanged.";goto finish;}swapped=YES;
    interrupt_test("after-swap");
    if(!output_matches(outputs,save())){if(!renamex_np(save().fileSystemRepresentation,stage.fileSystemRepresentation,RENAME_SWAP))swapped=NO;why=@"The installed save did not verify. Restore the before-import backup if needed.";goto finish;}
    applied=YES;
    }
 finish:
    if(applied){plan[@"phase"]=@"completed";write_plan(plan,job);result(@"Mii import applied. The previous island is in Backups.",NO);duo_save_set_pending(nil);fprintf(stderr,"Mii import: applied with a verified backup.\n");return YES;}
    result(why?:@"The Mii import could not be completed.",YES);
    fprintf(stderr,"【紅】Mii import: %s (swap=%d).\n",(why?:@"Unknown failure").UTF8String,swapped);
    duo_save_set_pending(nil);return YES;
}
