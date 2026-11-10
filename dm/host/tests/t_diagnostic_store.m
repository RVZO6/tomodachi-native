// 報告配額、原子說明修改、路徑驗證與分享封裝測試；只用暫存的人工資料。
// Test report quotas, atomic note edits, path checks and sharing archives with temporary synthetic data only.
#import "../../ios/Sources/DmDiagnosticStore.h"
#include <assert.h>
#include <errno.h>

int main(int argc,char **argv){@autoreleasepool{
    assert(argc==2);NSURL *base=[NSURL fileURLWithPath:@(argv[1]) isDirectory:YES],*root=[base URLByAppendingPathComponent:@"reports"],*exports=[base URLByAppendingPathComponent:@"exports"];
    DmDiagnosticStore *store=[[DmDiagnosticStore alloc] initWithRoot:root exports:exports];store.limitBytes=4096;
    NSDictionary *files=@{@"logs.txt":[@"synthetic log\n" dataUsingEncoding:NSUTF8StringEncoding],@"timings.csv":[NSMutableData dataWithLength:2000],@"screenshot.jpg":[@"synthetic image" dataUsingEncoding:NSUTF8StringEncoding],@"thumbnail.jpg":[NSData data]};
    NSDictionary *meta=@{@"created":@1234,@"actual_history_seconds":@60};NSError *e=nil;
    NSString *identifier=[store saveFiles:files metadata:meta note:@"First note" error:&e];assert(identifier&&store.reports.count==1&&[store usedBytes]<=4096);
    e=nil;assert(![store saveFiles:files metadata:meta note:@"Too much" error:&e]&&e.code==EDQUOT&&store.reports.count==1);
    store.limitBytes=1;assert(store.reports.count==1);e=nil;assert([store updateNote:@"First note" report:identifier error:&e]);assert(![store updateNote:@"edit" report:identifier error:&e]&&e.code==EDQUOT);
    store.limitBytes=16384;e=nil;assert([store updateNote:@"Edited note / 聲音中斷" report:identifier error:&e]);assert([store.reports[0][@"note"] isEqualToString:@"Edited note / 聲音中斷"]);
    e=nil;assert(![store deleteReports:@[@"../../save"] error:&e]&&store.reports.count==1);
    e=nil;assert(![store saveFiles:@{@"../escape":[NSData data]} metadata:meta note:@"" error:&e]);
    NSURL *outside=[base URLByAppendingPathComponent:@"private.txt"];[[@"PRIVATE NOT FOR EXPORT" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:outside atomically:YES];
    NSURL *thumb=[[root URLByAppendingPathComponent:identifier] URLByAppendingPathComponent:@"thumbnail.jpg"];
    [NSFileManager.defaultManager removeItemAtURL:thumb error:nil];assert([NSFileManager.defaultManager createSymbolicLinkAtURL:thumb withDestinationURL:outside error:&e]);
    NSURL *staging=[root URLByAppendingPathComponent:[@".capture-" stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString]];assert([NSFileManager.defaultManager createDirectoryAtURL:staging withIntermediateDirectories:NO attributes:nil error:&e]);
    store=[[DmDiagnosticStore alloc] initWithRoot:root exports:exports];store.limitBytes=16384;assert(store.reports.count==1&&![NSFileManager.defaultManager fileExistsAtPath:staging.path]);
    e=nil;NSURL *zip=[store exportReports:@[identifier] error:&e];assert(zip&&[[NSData dataWithContentsOfURL:zip] length]<=store.limitBytes);
    printf("%s\n",zip.fileSystemRepresentation);
    NSURL *link=[base URLByAppendingPathComponent:@"linked-root"];assert([NSFileManager.defaultManager createSymbolicLinkAtURL:link withDestinationURL:root error:&e]);
    DmDiagnosticStore *unsafe=[[DmDiagnosticStore alloc] initWithRoot:link exports:[base URLByAppendingPathComponent:@"other-exports"]];e=nil;assert(![unsafe deleteReports:@[identifier] error:&e]&&store.reports.count==1);
    NSURL *removed=[base URLByAppendingPathComponent:@"removed-reports"];
    DmDiagnosticStore *recover=[[DmDiagnosticStore alloc] initWithRoot:removed exports:[base URLByAppendingPathComponent:@"recover-export"]];
    assert([NSFileManager.defaultManager removeItemAtURL:removed error:&e]);assert([recover usedBytes]==0);
    assert([recover saveFiles:files metadata:meta note:@"Recreated after Files deletion" error:&e]);
    return 0;
}}
