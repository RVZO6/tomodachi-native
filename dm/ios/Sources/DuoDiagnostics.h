// 診斷功能的外殼介面；錄製與畫面按鍵的顯示是獨立設定。
// Shell interface for diagnostics; recording and on-screen button visibility are independent settings.
#import <UIKit/UIKit.h>
FOUNDATION_EXPORT NSNotificationName const DuoDiagnosticsChanged;
void duo_diagnostics_boot(NSString *documents);
void duo_diagnostics_flush(void);
BOOL duo_diagnostics_button_visible(void);
BOOL duo_diagnostics_busy(void);
void duo_diagnostics_request(void);
void duo_diagnostics_refresh(void);
UIView *duo_diagnostics_settings(CGFloat width, CGFloat scale, void (^changed)(void));

// 遊戲前端提供強實現；預覽 App 用弱實現。
// The game front end provides strong implementations; the preview app uses weak implementations.
void duo_game_diagnostic_screenshot(void (^done)(UIImage *image, NSString *failure));
BOOL duo_game_diagnostic_pause(BOOL pause);
NSDictionary *duo_game_diagnostic_metadata(void);
