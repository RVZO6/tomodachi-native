// 原生 Mii 檔案服務：只讀快照、驗證、排程，下次開機才換入存檔。
// Native Mii file services: read snapshots, validate and queue; install the save only at the next boot.
#pragma once
#import <Foundation/Foundation.h>
NSArray<NSDictionary *> *duo_mii_roster(NSString **error);
NSDictionary *duo_mii_read_file(NSURL *url, NSString **error);
BOOL duo_mii_queue(NSDictionary *input, NSDictionary *target, NSString **error);
NSURL *duo_mii_export(NSDictionary *target, NSString **error);
BOOL duo_mii_apply_pending(NSString *action);
void duo_mii_discard_pending(NSString *action);
NSString *duo_mii_take_result(void);
