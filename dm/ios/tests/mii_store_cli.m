// 只允許帶測試標記的私有目錄；不能誤把正式存檔當測試輸出。
// Require a test marker in an isolated directory; never use the live save as test output.
#import <Foundation/Foundation.h>
#include "../Sources/duo_mii.h"
#include "../Sources/duo_save_store.h"
int main(int argc,char**argv){@autoreleasepool{
 if(argc<3)return 2;NSString*dir=@(argv[1]);if(![[NSFileManager defaultManager] fileExistsAtPath:[dir stringByAppendingPathComponent:@".mii-test-workspace"]])return 3;
 setenv("DM_MII_TEST_DOCUMENTS",dir.fileSystemRepresentation,1);NSString*suite=[@"org.nxnative.mii-test." stringByAppendingString:dir.lastPathComponent];setenv("DM_MII_TEST_SUITE",suite.UTF8String,1);
 NSString*command=@(argv[2]),*why=nil;
 if([command isEqual:@"list"]){NSArray*r=duo_mii_roster(&why);if(!r){fprintf(stderr,"%s\n",why.UTF8String);return 1;}printf("COUNT %lu\n",(unsigned long)r.count);return 0;}
 if([command isEqual:@"apply"]){duo_save_apply_pending();NSString*r=duo_mii_take_result();printf("%s\n",(r?:@"No import result").UTF8String);return [r hasPrefix:@"Mii import applied"]?0:1;}
 if([command isEqual:@"cancel"]){duo_save_set_pending(nil);return 0;}
 if([command isEqual:@"queue"]&&argc==5){NSArray*r=duo_mii_roster(&why);NSDictionary*target=nil;for(NSDictionary*d in r)if([d[@"slot"] intValue]==atoi(argv[4]))target=d;NSDictionary*input=duo_mii_read_file([NSURL fileURLWithPath:@(argv[3])],&why);if(!input||!target||!duo_mii_queue(input,target,&why)){fprintf(stderr,"%s\n",(why?:@"Missing target").UTF8String);return 1;}puts("QUEUED");return 0;}
 if([command isEqual:@"export"]&&argc==5){NSArray*r=duo_mii_roster(&why);NSDictionary*target=nil;for(NSDictionary*d in r)if([d[@"slot"] intValue]==atoi(argv[3]))target=d;NSURL*u=duo_mii_export(target,&why);if(!u){fprintf(stderr,"%s\n",why.UTF8String);return 1;}BOOL ok=[[NSFileManager defaultManager] copyItemAtURL:u toURL:[NSURL fileURLWithPath:@(argv[4])] error:nil];[[NSFileManager defaultManager] removeItemAtURL:u.URLByDeletingLastPathComponent error:nil];return ok?0:1;}
 return 2;
}}
