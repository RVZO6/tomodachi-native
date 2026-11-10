// 與 UIKit 無關的存檔服務；方便以獨立副本測試啓動交易。
// UIKit-independent save services, for testing boot transactions on isolated copies.
#pragma once
#import <Foundation/Foundation.h>
NSString *duo_save_documents(void);
NSUserDefaults *duo_save_preferences(void);
NSArray<NSDictionary *> *duo_backups(void);
NSString *duo_backup_now(int *err);
NSString *duo_backup_before_mii(int *err);
NSURL *duo_save_export_copy(int *err);
int duo_save_snapshot_to(NSString *dst);
NSString *duo_save_pending(void);
void duo_save_set_pending(NSString *action);
void duo_save_apply_pending(void);
void duo_save_note_failure(NSString *what);
NSString *duo_save_take_failure(void);
