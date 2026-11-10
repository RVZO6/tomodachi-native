// 報告儲存：明確配額、不自動刪除已存報告、單一有界匯出；由呼叫方的序列佇列使用。
// Report storage: explicit quota, no automatic deletion of saved reports, one bounded export; use on a serial queue.
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface DmDiagnosticStore : NSObject
@property(nonatomic) uint64_t limitBytes;
@property(nonatomic,strong,readonly) NSURL *root;
- (instancetype)initWithRoot:(NSURL *)root exports:(NSURL *)exports;
- (uint64_t)usedBytes;
- (NSArray<NSDictionary *> *)reports;
- (nullable NSString *)saveFiles:(NSDictionary<NSString *,NSData *> *)files metadata:(NSDictionary *)metadata note:(NSString *)note error:(NSError **)error;
- (BOOL)updateNote:(NSString *)note report:(NSString *)identifier error:(NSError **)error;
- (BOOL)deleteReports:(NSArray<NSString *> *)identifiers error:(NSError **)error;
- (nullable NSURL *)exportReports:(NSArray<NSString *> *)identifiers error:(NSError **)error;
- (void)clearExport;
@end
NS_ASSUME_NONNULL_END
