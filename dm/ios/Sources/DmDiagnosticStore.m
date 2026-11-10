// 報告與說明放在同一目錄；ZIP 只在分享時建立，分享結束後清掉。
// Keep each report and its note together; build a ZIP only for sharing, then remove it.
#import "DmDiagnosticStore.h"
#include <errno.h>
#include <stdio.h>
#include <stdint.h>
#include <sys/stat.h>

static BOOL fail(NSError **e, int code, NSString *why) {
    if (e) *e = [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey:why}]; return NO;
}
static BOOL realDirectory(NSURL *u) {
    struct stat s;return u&&!lstat(u.fileSystemRepresentation,&s)&&S_ISDIR(s.st_mode);
}
static BOOL realFile(NSURL *u) {
    struct stat s;return u&&!lstat(u.fileSystemRepresentation,&s)&&S_ISREG(s.st_mode);
}
static uint64_t sizeOf(NSURL *u) { struct stat s;return u&&!lstat(u.fileSystemRepresentation,&s)&&s.st_size>0?(uint64_t)s.st_size:0; }
static NSString *validID(NSString *s) { NSUUID *u=[[NSUUID alloc] initWithUUIDString:s]; return u && [s.lowercaseString isEqualToString:u.UUIDString.lowercaseString] ? s.lowercaseString : nil; }
static NSArray *fileNames(void) { return @[@"report.json",@"logs.txt",@"timings.csv",@"screenshot.jpg",@"thumbnail.jpg"]; }

// 不壓縮的標準 ZIP：串流寫入，避免分享時把整批報告再放進記憶體。
// Standard stored ZIP: stream writes instead of loading the whole selection into memory.
static void put16(FILE *f,uint16_t v) { fputc(v&255,f); fputc(v>>8,f); }
static void put32(FILE *f,uint32_t v) { put16(f,v&65535); put16(f,v>>16); }
static uint32_t crc(NSData *data) {
    static uint32_t table[256]; static dispatch_once_t once;
    dispatch_once(&once, ^{ for(unsigned i=0;i<256;i++){uint32_t c=i;for(int j=0;j<8;j++)c=c&1?(c>>1)^0xedb88320:c>>1;table[i]=c;} });
    uint32_t c=~0u; const unsigned char *p=data.bytes;
    for(NSUInteger i=0;i<data.length;i++)c=table[(c^p[i])&255]^(c>>8); return ~c;
}
static BOOL addZip(FILE *f,NSMutableArray *central,NSString *name,NSData *data,uint64_t cap) {
    if (!data || central.count>=65535 || data.length>UINT32_MAX || ftello(f)<0 || (uint64_t)ftello(f)+data.length+name.length+128>cap) return NO;
    NSData *nm=[name dataUsingEncoding:NSUTF8StringEncoding]; uint32_t sum=crc(data),off=(uint32_t)ftello(f),n=(uint32_t)data.length;
    put32(f,0x04034b50);put16(f,20);put16(f,0x800);put16(f,0);put16(f,0);put16(f,33);put32(f,sum);put32(f,n);put32(f,n);put16(f,(uint16_t)nm.length);put16(f,0);
    if(fwrite(nm.bytes,1,nm.length,f)!=nm.length || fwrite(data.bytes,1,n,f)!=n)return NO;
    [central addObject:@{@"name":nm,@"crc":@(sum),@"off":@(off),@"size":@(n)}]; return !ferror(f);
}

@implementation DmDiagnosticStore { NSURL *_exports; }
- (instancetype)initWithRoot:(NSURL *)root exports:(NSURL *)exports {
    if((self=[super init])) {
        _root=root;_exports=exports;_limitBytes=50000000;
        NSFileManager *fm=NSFileManager.defaultManager;
        [self ensureRoot];
        if(realDirectory(root)) for(NSURL *u in [fm contentsOfDirectoryAtURL:root includingPropertiesForKeys:nil options:0 error:nil])
            if([u.lastPathComponent hasPrefix:@".capture-"] && validID([u.lastPathComponent substringFromIndex:9]) && realDirectory(u)) [fm removeItemAtURL:u error:nil];
        [self clearExport];
    }return self;
}
- (BOOL)ensureRoot {
    if(realDirectory(_root))return YES;
    if([NSFileManager.defaultManager attributesOfItemAtPath:_root.path error:nil])return NO;
    if(![NSFileManager.defaultManager createDirectoryAtURL:_root withIntermediateDirectories:YES attributes:nil error:nil]||!realDirectory(_root))return NO;
    [_root setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];return YES;
}
- (uint64_t)usedBytes {
    if(![self ensureRoot])return UINT64_MAX;
    __block BOOL bad=NO;uint64_t n=0; NSDirectoryEnumerator *en=[NSFileManager.defaultManager enumeratorAtURL:_root includingPropertiesForKeys:@[NSURLIsSymbolicLinkKey,NSURLIsRegularFileKey,NSURLFileSizeKey] options:0 errorHandler:^BOOL(NSURL *u,NSError *e){(void)u;(void)e;bad=YES;return NO;}];
    if(!en)return UINT64_MAX;
    for(NSURL *u in en) { struct stat s;if(lstat(u.fileSystemRepresentation,&s)){bad=YES;[en skipDescendants];continue;}if(S_ISLNK(s.st_mode)){[en skipDescendants];continue;}if(S_ISREG(s.st_mode)&&s.st_size>0)n+=(uint64_t)s.st_size; }
    return bad?UINT64_MAX:n;
}
- (NSURL *)directory:(NSString *)identifier { NSString *s=validID(identifier);return s?[_root URLByAppendingPathComponent:s isDirectory:YES]:nil; }
- (NSDictionary *)read:(NSString *)identifier {
    NSURL *dir=[self directory:identifier],*u=[dir URLByAppendingPathComponent:@"report.json"];
    if(!realDirectory(_root)||!realDirectory(dir)||!realFile(u)||sizeOf(u)>65536)return nil;
    NSData *d=[NSData dataWithContentsOfURL:u];id obj=d?[NSJSONSerialization JSONObjectWithData:d options:0 error:nil]:nil;
    if(![obj isKindOfClass:NSDictionary.class]||![obj[@"id"] isEqualToString:identifier]||![obj[@"created"] isKindOfClass:NSNumber.class]||![obj[@"note"] isKindOfClass:NSString.class]||![obj[@"actual_history_seconds"] isKindOfClass:NSNumber.class])return nil;
    return obj;
}
- (NSArray<NSDictionary *> *)reports {
    if(![self ensureRoot])return @[];
    NSMutableArray *out=[NSMutableArray array];
    for(NSURL *dir in [NSFileManager.defaultManager contentsOfDirectoryAtURL:_root includingPropertiesForKeys:nil options:0 error:nil]) {
        NSString *identifier=validID(dir.lastPathComponent);if(!identifier)continue;
        NSDictionary *meta=[self read:identifier];if(!meta)continue;
        NSMutableDictionary *r=[meta mutableCopy];uint64_t size=0;
        for(NSString *f in fileNames()){NSURL *u=[dir URLByAppendingPathComponent:f];if(realFile(u))size+=sizeOf(u);}
        r[@"bytes"]=@(size);r[@"directory"]=dir;[out addObject:r];
    }
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [b[@"created"] compare:a[@"created"]];}];return out;
}
- (NSData *)json:(NSDictionary *)metadata identifier:(NSString *)identifier note:(NSString *)note error:(NSError **)error {
    if([note lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>8192){fail(error,EFBIG,@"Description is too long.");return nil;}
    NSMutableDictionary *m=[metadata mutableCopy];m[@"id"]=identifier;m[@"note"]=note;m[@"format"]=@1;
    if(![NSJSONSerialization isValidJSONObject:m]){fail(error,EINVAL,@"Report metadata is invalid.");return nil;}
    NSData *d=[NSJSONSerialization dataWithJSONObject:m options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:error];
    if(d.length>65536){fail(error,EFBIG,@"Report metadata is too large.");return nil;}return d;
}
- (NSString *)saveFiles:(NSDictionary<NSString *,NSData *> *)files metadata:(NSDictionary *)meta note:(NSString *)note error:(NSError **)error {
    if(![self ensureRoot]){fail(error,EINVAL,@"Report directory is not a regular directory.");return nil;}
    NSString *identifier=NSUUID.UUID.UUIDString.lowercaseString;
    NSData *json=[self json:meta identifier:identifier note:note error:error];if(!json)return nil;
    NSMutableDictionary *all=[files mutableCopy];all[@"report.json"]=json;uint64_t bytes=0;
    for(NSString *n in all){if(![fileNames() containsObject:n]||![all[n] isKindOfClass:NSData.class]){fail(error,EINVAL,@"Unknown report file.");return nil;}bytes+=[all[n] length];}
    uint64_t used=[self usedBytes];if(used>_limitBytes||bytes>_limitBytes-used){fail(error,EDQUOT,@"Report storage limit reached.");return nil;}
    NSURL *temp=[_root URLByAppendingPathComponent:[@".capture-" stringByAppendingString:identifier] isDirectory:YES];
    NSFileManager *fm=NSFileManager.defaultManager;
    if(![fm createDirectoryAtURL:temp withIntermediateDirectories:NO attributes:nil error:error])return nil;
    BOOL ok=YES;
    for(NSString *n in all)if(![all[n] writeToURL:[temp URLByAppendingPathComponent:n] options:0 error:error]){ok=NO;break;}
    if(ok)ok=[fm moveItemAtURL:temp toURL:[self directory:identifier] error:error];
    if(!ok){[fm removeItemAtURL:temp error:nil];return nil;}return identifier;
}
- (BOOL)updateNote:(NSString *)note report:(NSString *)identifier error:(NSError **)error {
    NSDictionary *m=[self read:identifier];if(!m)return fail(error,ENOENT,@"Report was not found.");
    if([m[@"note"] isEqualToString:note])return YES;
    NSData *d=[self json:m identifier:identifier note:note error:error];if(!d)return NO;
    // 原子替換也計入暫存檔的最高用量；滿額時不偷偷刪除別的報告。
    // Count the temporary file for atomic replacement too; never delete another report to make room.
    uint64_t used=[self usedBytes];if(used>_limitBytes||d.length>_limitBytes-used)return fail(error,EDQUOT,@"Free a little report storage before editing the note.");
    return [d writeToURL:[[self directory:identifier] URLByAppendingPathComponent:@"report.json"] options:NSDataWritingAtomic error:error];
}
- (BOOL)deleteReports:(NSArray<NSString *> *)ids error:(NSError **)error {
    if(!realDirectory(_root))return fail(error,EINVAL,@"Report directory is not available.");
    for(NSString *identifier in ids){NSURL *dir=[self directory:identifier];if(!dir||![self read:identifier])return fail(error,EINVAL,@"Invalid report identifier.");}
    for(NSString *identifier in ids)if(![NSFileManager.defaultManager removeItemAtURL:[self directory:identifier] error:error])return NO;
    return YES;
}
- (void)clearExport {
    NSFileManager *fm=NSFileManager.defaultManager;
    if([fm attributesOfItemAtPath:_exports.path error:nil]&&!realDirectory(_exports))return;
    if(realDirectory(_exports))[fm removeItemAtURL:_exports error:nil];
    [fm createDirectoryAtURL:_exports withIntermediateDirectories:YES attributes:nil error:nil];
    [_exports setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
}
- (NSURL *)exportReports:(NSArray<NSString *> *)ids error:(NSError **)error {
    if(!ids.count||!realDirectory(_root)||!realDirectory(_exports)){fail(error,EINVAL,@"Select a report to share.");return nil;}
    [self clearExport];
    if(!realDirectory(_exports)){fail(error,EINVAL,@"Export directory is not available.");return nil;}
    NSMutableString *index=[NSMutableString stringWithString:@"Diagnostic reports\n\n"];
    for(NSString *identifier in ids){NSDictionary *m=[self read:identifier];if(!m){fail(error,EINVAL,@"Report was not found.");return nil;}[index appendFormat:@"%@\n%@\n\n",identifier,m[@"note"]?:@""];}
    NSURL *zip=[_exports URLByAppendingPathComponent:@"Diagnostic-reports.zip"];
    FILE *f=fopen(zip.fileSystemRepresentation,"wb");if(!f){fail(error,errno,@"Cannot create report export.");return nil;}
    NSMutableArray *central=[NSMutableArray array];BOOL ok=addZip(f,central,@"Descriptions.txt",[index dataUsingEncoding:NSUTF8StringEncoding],_limitBytes);
    for(NSString *identifier in ids)for(NSString *name in fileNames()) {@autoreleasepool{
        if(!ok)break;
        NSURL *u=[[self directory:identifier] URLByAppendingPathComponent:name];if(!realFile(u))continue;
        if(sizeOf(u)>_limitBytes){ok=NO;break;}
        NSData *d=[NSData dataWithContentsOfURL:u options:NSDataReadingMappedIfSafe error:error];
        ok=d&&addZip(f,central,[identifier stringByAppendingPathComponent:name],d,_limitBytes);
    }}
    uint32_t start=(uint32_t)ftello(f);
    if(ok)for(NSDictionary *entry in central){NSData *nm=entry[@"name"];uint32_t n=[entry[@"size"] unsignedIntValue];
        put32(f,0x02014b50);put16(f,20);put16(f,20);put16(f,0x800);put16(f,0);put16(f,0);put16(f,33);put32(f,[entry[@"crc"] unsignedIntValue]);put32(f,n);put32(f,n);put16(f,(uint16_t)nm.length);put16(f,0);put16(f,0);put16(f,0);put16(f,0);put32(f,0);put32(f,[entry[@"off"] unsignedIntValue]);if(fwrite(nm.bytes,1,nm.length,f)!=nm.length)ok=NO;
    }
    uint32_t end=(uint32_t)ftello(f);
    if(ok){put32(f,0x06054b50);put16(f,0);put16(f,0);put16(f,(uint16_t)central.count);put16(f,(uint16_t)central.count);put32(f,end-start);put32(f,start);put16(f,0);}
    if(ferror(f)||ftello(f)<0||(uint64_t)ftello(f)>_limitBytes)ok=NO;
    if(fclose(f))ok=NO;
    if(!ok){[NSFileManager.defaultManager removeItemAtURL:zip error:nil];if(error&&!*error)fail(error,EFBIG,@"Export exceeds the report storage limit, or could not be written.");return nil;}return zip;
}
@end
