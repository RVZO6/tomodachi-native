// 診斷擷取、說明、配額與分享；沒有網路端點，也不錄影或錄音。
// Diagnostic capture, notes, quota and sharing; no network endpoint, video recording or audio recording.
#import "DuoDiagnostics.h"
#import "DmDiagnosticStore.h"
#import "duo_shell.h"
#include "dm_diagnostics.h"
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <errno.h>
#include <stdatomic.h>

NSNotificationName const DuoDiagnosticsChanged=@"DuoDiagnosticsChanged";
static BOOL zh(void){return [NSLocale.preferredLanguages.firstObject hasPrefix:@"zh"];}
static NSString *L(NSString *z,NSString *e){return zh()?z:e;}
static NSUserDefaults *prefs(void){return NSUserDefaults.standardUserDefaults;}
static BOOL recording(void){return ![prefs() objectForKey:@"DiagnosticRecording"]||[prefs() boolForKey:@"DiagnosticRecording"];}
static unsigned history(void){NSInteger n=[prefs() integerForKey:@"DiagnosticHistory"];return (unsigned)(n>=10&&n<=300?n:60);}
static unsigned limitMB(void){NSInteger n=[prefs() integerForKey:@"DiagnosticLimitMB"];return (unsigned)(n>=5&&n<=500?n:50);}
BOOL duo_diagnostics_button_visible(void){return ![prefs() objectForKey:@"DiagnosticButton"]||[prefs() boolForKey:@"DiagnosticButton"];}
static uint64_t limitBytes(void){return (uint64_t)limitMB()*1000000;}
static void changed(void){[[NSNotificationCenter defaultCenter] postNotificationName:DuoDiagnosticsChanged object:nil];}

// stderr 的呼叫方只寫記憶體；獨立佇列每秒把新資料寫到有界的舊式日誌。
// stderr callers write memory only; a separate queue drains new bytes into the bounded legacy log once a second.
static dispatch_queue_t logQueue;
static dispatch_source_t logTimer;
static uint64_t logCursor;
static int logWrite(void *cookie,const char *p,int n){(void)cookie;if(n>0)dm_diag_log_write(p,(size_t)n);return n;}
static void drainLog(void){
    char bytes[65536];
    for(int i=0;i<4;i++){
        size_t n=dm_diag_logs_after(&logCursor,bytes,sizeof bytes);if(!n)break;
        struct stat s;if(fstat(STDERR_FILENO,&s)||s.st_size+(off_t)n>256*1024){if(ftruncate(STDERR_FILENO,0)==0)lseek(STDERR_FILENO,0,SEEK_SET);}
        size_t at=0;while(at<n){ssize_t k=write(STDERR_FILENO,bytes+at,n-at);if(k<0&&errno==EINTR)continue;if(k<=0)break;at+=(size_t)k;}
    }
}
void duo_diagnostics_flush(void){if(logQueue)dispatch_sync(logQueue,^{drainLog();});}
void duo_diagnostics_boot(NSString *doc){
    static dispatch_once_t once;dispatch_once(&once,^{
        NSString *path=[doc stringByAppendingPathComponent:@"log.txt"],*prev=[doc stringByAppendingPathComponent:@"log.prev.txt"];
        NSFileHandle *old=[NSFileHandle fileHandleForReadingAtPath:path];
        if(old){@try{unsigned long long end=[old seekToEndOfFile];[old seekToFileOffset:end>256*1024?end-256*1024:0];[[old readDataToEndOfFile] writeToFile:prev atomically:YES];[old closeFile];}@catch(NSException *e){(void)e;}}
        else [NSFileManager.defaultManager removeItemAtPath:prev error:nil];
        if(freopen(path.fileSystemRepresentation,"w",stderr))setvbuf(stderr,NULL,_IONBF,0);
        dm_diag_configure(recording());
        FILE *sink=fwopen(NULL,logWrite);if(sink){setvbuf(sink,NULL,_IONBF,0);stderr=sink;}
        logQueue=dispatch_queue_create("diagnostics.legacy-log",DISPATCH_QUEUE_SERIAL);
        logTimer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,logQueue);
        dispatch_source_set_timer(logTimer,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),NSEC_PER_SEC,100*NSEC_PER_MSEC);
        dispatch_source_set_event_handler(logTimer,^{drainLog();});dispatch_resume(logTimer);atexit(duo_diagnostics_flush);
    });
}

__attribute__((weak)) void duo_game_diagnostic_screenshot(void (^done)(UIImage *,NSString *)){UIImage *im=duo_asset(@"picture");done(im,im?nil:@"No preview screenshot is available.");}
__attribute__((weak)) BOOL duo_game_diagnostic_pause(BOOL pause){(void)pause;return NO;}
__attribute__((weak)) NSDictionary *duo_game_diagnostic_metadata(void){return @{@"host":@"shell-preview"};}

static UILabel *text(NSString *s,CGFloat size,UIFontWeight weight){UILabel *v=[UILabel new];v.text=s;v.textColor=duo_rgb(DUO_NAVY);v.font=duo_font(size,weight);v.numberOfLines=0;return v;}
static CGFloat fit(UILabel *v,CGFloat x,CGFloat y,CGFloat w){CGFloat h=ceil([v sizeThatFits:CGSizeMake(w,CGFLOAT_MAX)].height);v.frame=CGRectMake(x,y,w,h);return h;}
static NSString *when(NSNumber *time){NSDateFormatter *f=[NSDateFormatter new];f.dateStyle=NSDateFormatterShortStyle;f.timeStyle=NSDateFormatterShortStyle;return [f stringFromDate:[NSDate dateWithTimeIntervalSince1970:time.doubleValue]];}
static NSString *mb(uint64_t bytes){return [NSString stringWithFormat:@"%.1f MB",bytes/1000000.0];}
static NSData *jpeg(UIImage *im,CGFloat side,CGFloat quality){
    if(!im)return nil;CGSize s=im.size;CGFloat k=MIN(1,side/MAX(s.width,s.height));s=CGSizeMake(MAX(1,floor(s.width*k)),MAX(1,floor(s.height*k)));
    UIGraphicsImageRendererFormat *f=[UIGraphicsImageRendererFormat defaultFormat];f.scale=1;f.opaque=YES;
    UIImage *small=[[[UIGraphicsImageRenderer alloc] initWithSize:s format:f] imageWithActions:^(UIGraphicsImageRendererContext *c){(void)c;[im drawInRect:(CGRect){CGPointZero,s}];}];return UIImageJPEGRepresentation(small,quality);
}
static UIImage *alphaMask(UIImage *grey){
    if(!grey.CGImage)return nil;size_t w=CGImageGetWidth(grey.CGImage),h=CGImageGetHeight(grey.CGImage),n=w*h;
    CGColorSpaceRef cs=CGColorSpaceCreateDeviceRGB();
    CGContextRef c=CGBitmapContextCreate(NULL,w,h,8,w*4,cs,(CGBitmapInfo)kCGImageAlphaPremultipliedLast);CGColorSpaceRelease(cs);
    if(!c)return nil;unsigned char *bytes=CGBitmapContextGetData(c);CGContextDrawImage(c,CGRectMake(0,0,w,h),grey.CGImage);
    for(size_t i=0;i<n;i++){unsigned char a=bytes[i*4];bytes[i*4]=bytes[i*4+1]=bytes[i*4+2]=bytes[i*4+3]=a;}
    CGImageRef out=CGBitmapContextCreateImage(c);UIImage *im=[UIImage imageWithCGImage:out];CGImageRelease(out);CGContextRelease(c);return im;
}

@class DuoDiagnosticManager;
@interface DuoDiagnosticOverlay : UIView <UITextViewDelegate>
@property(nonatomic,copy) void (^cancel)(void);
@property(nonatomic,copy) NSString *note;
- (instancetype)initWithMode:(NSString *)mode title:(NSString *)title info:(NSString *)info body:(NSString *)body image:(UIImage *)image note:(NSString *)note actions:(NSArray<NSDictionary *> *)actions;
- (void)focusNumber:(NSString *)value unit:(NSString *)unit;
@end
@implementation DuoDiagnosticOverlay {
    NSString *_mode;UIView *_card,*_backdrop,*_numberWell;UIScrollView *_scroll;CALayer *_pattern;UILabel *_title,*_info,*_body,*_noteLabel,*_unit;
    UIImageView *_image;UITextView *_notes;UITextField *_number;NSArray<DuoPill *> *_buttons;CGFloat _keyboard;
}
- (instancetype)initWithMode:(NSString *)mode title:(NSString *)title info:(NSString *)info body:(NSString *)body image:(UIImage *)image note:(NSString *)note actions:(NSArray<NSDictionary *> *)actions {
    if((self=[super initWithFrame:CGRectZero])){
        _mode=mode;self.backgroundColor=[UIColor colorWithWhite:0 alpha:.34];self.accessibilityViewIsModal=YES;
        _scroll=[UIScrollView new];_scroll.contentInsetAdjustmentBehavior=UIScrollViewContentInsetAdjustmentNever;[self addSubview:_scroll];_card=[UIView new];[_scroll addSubview:_card];
        // 只裁剪背景，不裁剪按鍵與文字（與遊戲的獨立背景圖層相同）。
        // Mask only the background, not buttons or text, as with the game's separate background layer.
        _backdrop=[UIView new];_backdrop.backgroundColor=duo_rgb(0xFFD97F);[_card addSubview:_backdrop];
        UIImage *shape=alphaMask(duo_asset(@"dialog_cloud"));if(shape){CALayer *mask=[CALayer layer];mask.contents=(id)shape.CGImage;_backdrop.layer.mask=mask;}
        UIImage *pattern=alphaMask(duo_asset(@"doodle"));if(pattern){_pattern=[CALayer layer];_pattern.backgroundColor=duo_rgb(0xFFE49B).CGColor;CALayer *m=[CALayer layer];m.contents=(id)pattern.CGImage;m.contentsGravity=kCAGravityResize;_pattern.mask=m;[_backdrop.layer addSublayer:_pattern];}
        _title=text(title,26,UIFontWeightHeavy);_info=text(info,15,UIFontWeightSemibold);_body=text(body,17,UIFontWeightBold);
        for(UILabel *v in @[_title,_info,_body]){v.textAlignment=NSTextAlignmentCenter;[_card addSubview:v];}
        if(image){_image=[[UIImageView alloc] initWithImage:image];_image.contentMode=UIViewContentModeScaleAspectFit;[_card addSubview:_image];}
        if([mode isEqual:@"capture"]||[mode isEqual:@"detail"]){
            _noteLabel=text(L(@"說明（選填）",@"Note (optional)"),17,UIFontWeightBold);[_card addSubview:_noteLabel];
            _notes=[UITextView new];_notes.delegate=self;_notes.text=note?:@"";_notes.font=duo_font(17,UIFontWeightSemibold);_notes.textColor=duo_rgb(DUO_NAVY);_notes.backgroundColor=UIColor.whiteColor;_notes.layer.cornerRadius=22;_notes.textContainerInset=UIEdgeInsetsMake(10,12,10,12);_notes.accessibilityLabel=_noteLabel.text;[_card addSubview:_notes];
        }
        NSMutableArray *buttons=[NSMutableArray array];
        for(NSDictionary *a in actions){void (^tap)(void)=a[@"tap"];DuoPill *b=duo_make_pill(a[@"title"],nil,[a[@"style"] intValue],1,tap);[_card addSubview:b];[buttons addObject:b];}_buttons=buttons;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboard:) name:UIKeyboardWillChangeFrameNotification object:nil];
        self.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    }return self;
}
- (void)dealloc{[[NSNotificationCenter defaultCenter] removeObserver:self];}
- (void)keyboard:(NSNotification *)n{CGRect r=[self convertRect:[n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue] fromView:nil];_keyboard=MAX(0,CGRectGetMaxY(self.bounds)-CGRectGetMinY(r));[self setNeedsLayout];}
- (void)setNote:(NSString *)s{_notes.text=s;}
- (NSString *)note{return _number?_number.text?:@"":_notes.text?:@"";}
- (void)textViewDidChange:(UITextView *)v{if(v.markedTextRange)return;if(v.text.length>2000){NSRange last=[v.text rangeOfComposedCharacterSequenceAtIndex:1999];v.text=[v.text substringToIndex:NSMaxRange(last)>2000?last.location:2000];}}
- (void)focusNumber:(NSString *)value unit:(NSString *)unit{
    _numberWell=[UIView new];_numberWell.backgroundColor=UIColor.whiteColor;_numberWell.layer.cornerRadius=24;[_card addSubview:_numberWell];
    _number=[UITextField new];_number.text=value;_number.keyboardType=UIKeyboardTypeNumberPad;_number.textAlignment=NSTextAlignmentCenter;_number.font=duo_font(25,UIFontWeightBold);_number.textColor=duo_rgb(DUO_NAVY);_number.accessibilityLabel=[NSString stringWithFormat:@"%@ (%@)",_title.text,unit];[_numberWell addSubview:_number];
    _unit=text(unit,18,UIFontWeightBold);[_numberWell addSubview:_unit];[self setNeedsLayout];[_number becomeFirstResponder];
}
- (void)layoutSubviews{
    [super layoutSubviews];CGFloat w=MIN(self.bounds.size.width-12,650),pad=w<450?34:65,inner=w-2*pad,y=46;
    _title.font=duo_font(w<450?22:26,UIFontWeightHeavy);
    if(_image){CGFloat iw=w<450?74:112;_image.frame=CGRectMake(pad,y,iw,84);CGFloat x=pad+iw+18,tw=inner-iw-18;_title.textAlignment=_info.textAlignment=NSTextAlignmentLeft;y+=fit(_title,x,y,tw)+8;y+=fit(_info,x,y,tw);y=MAX(y,46+84)+17;}
    else {y+=fit(_title,pad,y,inner)+15;if(_info.text.length)y+=fit(_info,pad,y,inner)+14;}
    if(_body.text.length)y+=fit(_body,pad,y,inner)+18;
    if(_number){_numberWell.frame=CGRectMake(pad+inner/2-80,y,160,53);_number.frame=CGRectMake(0,0,100,53);_unit.frame=CGRectMake(100,0,60,53);y+=70;}
    if(_notes){y+=fit(_noteLabel,pad,y,inner)+8;_notes.frame=CGRectMake(pad,y,inner,MAX(74,_keyboard?84:82));y=CGRectGetMaxY(_notes.frame)+16;}
    int cols=_buttons.count==3?2:(int)MAX(1,_buttons.count);CGFloat gap=12,bw=(inner-gap*(cols-1))/cols;
    for(NSUInteger i=0;i<_buttons.count;i++){BOOL lastFull=_buttons.count==3&&i==2;_buttons[i].frame=CGRectMake(pad+(i%cols)*(bw+gap),y+(i/cols)*65,lastFull?inner:bw,55);}
    if(_buttons.count)y+=((_buttons.count+cols-1)/cols)*65;CGFloat h=y+46,avail=self.bounds.size.height-_keyboard;
    _scroll.frame=CGRectMake(0,0,self.bounds.size.width,MAX(1,avail));_scroll.contentSize=CGSizeMake(self.bounds.size.width,MAX(avail,h+10));
    _card.frame=CGRectMake((self.bounds.size.width-w)/2,MAX(0,(avail-h)/2),w,h);_backdrop.frame=_card.bounds;_backdrop.layer.mask.frame=_backdrop.bounds;
    _pattern.frame=_card.bounds;_pattern.mask.frame=_pattern.bounds;
}
@end

@interface DuoDiagnosticCapture:NSObject
@property(nonatomic,strong) NSDictionary *metadata;
@property(nonatomic,strong) NSDictionary<NSString *,NSData *> *files;
@property(nonatomic,strong) UIImage *preview;
@property(nonatomic,copy) NSString *note;
@property(nonatomic) double seconds;
@end
@implementation DuoDiagnosticCapture @end

@interface DuoDiagnosticManager:NSObject
@property(nonatomic,strong) NSArray<NSDictionary *> *reports;
@property(nonatomic) uint64_t used;
@property(nonatomic,strong) NSMutableSet<NSString *> *selected;
@property(nonatomic) NSUInteger visibleCount;
@property(nonatomic) BOOL capturing,exporting;
+ (instancetype)shared;
- (void)request;
- (void)refresh;
- (void)edit:(NSDictionary *)report;
- (void)remove:(NSArray<NSString *> *)ids;
- (void)share:(NSArray<NSString *> *)ids;
- (void)number:(BOOL)storage;
- (void)retry;
- (BOOL)hasPending;
@end
@implementation DuoDiagnosticManager {
    DmDiagnosticStore *_store;dispatch_queue_t _io;DuoDiagnosticCapture *_pending;DuoDiagnosticOverlay *_overlay,*_noteErrorEditor;
    BOOL _ownsPause,_cancelCapture,_showWhenActive,_resumeWhenActive;NSString *_deferredTitle,*_deferredBody;
}
+ (instancetype)shared{static DuoDiagnosticManager *m;static dispatch_once_t once;dispatch_once(&once,^{m=[self new];});return m;}
- (instancetype)init{
    if((self=[super init])){
        _reports=@[];_selected=[NSMutableSet set];_visibleCount=20;_io=dispatch_queue_create("diagnostics.reports",DISPATCH_QUEUE_SERIAL);
        NSString *doc=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject,*cache=NSSearchPathForDirectoriesInDomains(NSCachesDirectory,NSUserDomainMask,YES).firstObject;
        _store=[[DmDiagnosticStore alloc] initWithRoot:[NSURL fileURLWithPath:[doc stringByAppendingPathComponent:@"DiagnosticReports"] isDirectory:YES] exports:[NSURL fileURLWithPath:[cache stringByAppendingPathComponent:@"DiagnosticExport"] isDirectory:YES]];
        dm_diag_configure(recording());[self refresh];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(becameActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    }return self;
}
- (void)refresh{
    dispatch_async(_io,^{self->_store.limitBytes=limitBytes();NSArray *r=[self->_store reports];uint64_t used=[self->_store usedBytes];dispatch_async(dispatch_get_main_queue(),^{self.reports=r;self.used=used;NSMutableSet *valid=[NSMutableSet set];for(NSDictionary *m in r)[valid addObject:m[@"id"]];[self.selected intersectSet:valid];changed();});});
}
- (UIViewController *)host{UIViewController *vc=nil;for(UIScene *s in UIApplication.sharedApplication.connectedScenes)if([s isKindOfClass:UIWindowScene.class])for(UIWindow *w in ((UIWindowScene *)s).windows)if(w.isKeyWindow)vc=w.rootViewController;return vc;}
- (void)close:(BOOL)resume{
    [_overlay endEditing:YES];[_overlay removeFromSuperview];_overlay=nil;
    if(resume&&_ownsPause){if(UIApplication.sharedApplication.applicationState==UIApplicationStateActive){_ownsPause=NO;duo_game_diagnostic_pause(NO);}else _resumeWhenActive=YES;}changed();
}
- (void)becameActive:(NSNotification *)n{
    (void)n;if(_resumeWhenActive){_resumeWhenActive=NO;if(_ownsPause){_ownsPause=NO;duo_game_diagnostic_pause(NO);}}
    if(_deferredTitle){NSString *title=_deferredTitle,*body=_deferredBody;_deferredTitle=_deferredBody=nil;[self message:title body:body];return;}
    if(_showWhenActive){_showWhenActive=NO;[self presentPending];}
}
- (void)show:(DuoDiagnosticOverlay *)v{
    [self close:NO];UIViewController *vc=[self host];if(!vc)return;
    _overlay=v;v.frame=vc.view.bounds;[vc.view addSubview:v];UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification,v);changed();
}
- (NSDictionary *)button:(NSString *)s style:(int)style tap:(void (^)(void))tap{return @{@"title":s,@"style":@(style),@"tap":[tap copy]};}
- (void)message:(NSString *)title body:(NSString *)body{
    if(UIApplication.sharedApplication.applicationState!=UIApplicationStateActive){_deferredTitle=title;_deferredBody=body;_showWhenActive=NO;[self close:NO];return;}
    _ownsPause=duo_game_diagnostic_pause(YES)||_ownsPause;
    __weak typeof(self) ws=self;[self show:[[DuoDiagnosticOverlay alloc] initWithMode:@"message" title:title info:nil body:body image:nil note:nil actions:@[[self button:L(@"確定",@"OK") style:3 tap:^{DuoDiagnosticManager *s=ws;if(s->_noteErrorEditor){DuoDiagnosticOverlay *editor=s->_noteErrorEditor;s->_noteErrorEditor=nil;[s show:editor];}else[s close:YES];}]]]];
}
- (uint64_t)pendingBytes{uint64_t n=65536;for(NSData *d in _pending.files.allValues)n+=d.length;return n;}
- (void)presentPending{
    if(!_pending)return;
    // 背景期間不改遊戲暫停狀態；避免漏解生命週期的時鐘鎖或在背景恢復 GPU。
    // Do not change game pause state in the background: avoid stranded lifecycle clock holds or background GPU resume.
    if(UIApplication.sharedApplication.applicationState!=UIApplicationStateActive){_showWhenActive=YES;[self close:NO];return;}
    _ownsPause=duo_game_diagnostic_pause(YES)||_ownsPause;
    if(self.used==UINT64_MAX){[self message:L(@"無法使用報告目錄",@"Report storage unavailable") body:L(@"請檢查報告目錄的存取權限後再試一次。這份擷取仍留在記憶體裡。",@"Check access to the report folder and try again. Your capture is still held in memory.")];return;}
    __weak typeof(self) ws=self;BOOL full=self.used>limitBytes()||[self pendingBytes]>limitBytes()-MIN(self.used,limitBytes());
    if(full){
        NSString *info=[NSString stringWithFormat:L(@"已用 %.1f / %u MB\n本報告約需 %@。",@"%.1f / %u MB used\nThis capture needs about %@."),self.used/1000000.0,limitMB(),mb([self pendingBytes])];
        void (^manage)(void)=^{DuoDiagnosticManager *s=ws;[s close:NO];s->_ownsPause=NO;duo_shell_set_paused(YES);duo_shell_show_page(DUO_PAGE_DIAGNOSTICS);};
        [self show:[[DuoDiagnosticOverlay alloc] initWithMode:@"full" title:L(@"報告儲存空間已滿",@"Storage is full") info:info body:L(@"這份報告仍留在記憶體裡。\n請清出空間或提高上限。",@"Your capture is held in memory.\nFree some space or raise the limit.") image:nil note:nil actions:@[[self button:L(@"更改上限",@"Change limit") style:0 tap:manage],[self button:L(@"管理報告",@"Manage reports") style:3 tap:manage],[self button:L(@"捨棄這份報告",@"Discard this capture") style:0 tap:^{DuoDiagnosticManager *s=ws;s->_pending=nil;[s close:YES];}]]]];
    }else{
        NSString *info=[NSString stringWithFormat:L(@"已擷取最近 %.1f 秒。",@"The last %.1f seconds are captured."),_pending.seconds];
        if(!_pending.preview)info=[info stringByAppendingString:L(@"\n無法取得截圖。",@"\nScreenshot unavailable.")];
        [self show:[[DuoDiagnosticOverlay alloc] initWithMode:@"capture" title:L(@"發生了甚麼？",@"What happened?") info:info body:nil image:_pending.preview note:_pending.note actions:@[[self button:L(@"捨棄",@"Discard") style:0 tap:^{DuoDiagnosticManager *s=ws;s->_pending=nil;[s close:YES];}],[self button:L(@"儲存報告",@"Save report") style:3 tap:^{[ws savePending];}]]]];
    }
}
- (void)request{
    if(_capturing||_exporting)return;
    if(_pending){self.capturing=YES;changed();dispatch_async(_io,^{uint64_t used=[self->_store usedBytes];dispatch_async(dispatch_get_main_queue(),^{self.capturing=NO;self.used=used;[self presentPending];});});return;}
    if(!recording())return;
    uint64_t cutoff=dm_diag_now();unsigned requested=history();dm_diag_snapshot *snapshot=dm_diag_take(cutoff,requested);
    if(!snapshot){[self message:L(@"無法擷取",@"Capture failed") body:L(@"沒有足夠的記憶體。",@"Not enough memory.")];return;}
    self.capturing=YES;_cancelCapture=NO;NSDate *date=NSDate.date;
    NSDictionary *runtime=duo_game_diagnostic_metadata();NSDictionary *settings=@{@"history_seconds":@(requested),@"report_limit_mb":@(limitMB()),@"recording":@(recording()),@"aspect":[prefs() stringForKey:@"GameAspect"]?:@"screen",@"fps":[prefs() integerForKey:@"FrameRate"]==60?@60:@30};
    __weak typeof(self) ws=self;
    [self show:[[DuoDiagnosticOverlay alloc] initWithMode:@"busy" title:L(@"正在擷取…",@"Capturing…") info:nil body:nil image:nil note:nil actions:@[[self button:L(@"取消",@"Cancel") style:0 tap:^{DuoDiagnosticManager *s=ws;s->_cancelCapture=YES;[s close:YES];}]]]];
    duo_game_diagnostic_screenshot(^(UIImage *image,NSString *failure){
        DuoDiagnosticManager *s=ws;if(!s){dm_diag_snapshot_free(snapshot);return;}
        if(s->_cancelCapture){dm_diag_snapshot_free(snapshot);s.capturing=NO;changed();return;}
        if(UIApplication.sharedApplication.applicationState==UIApplicationStateActive)s->_ownsPause=duo_game_diagnostic_pause(YES)||s->_ownsPause;
        uint64_t screenshotAt=dm_diag_now();
        dispatch_async(s->_io,^{@autoreleasepool{
            char *events=NULL,*logs=NULL;size_t ne=0,nl=0;FILE *ef=open_memstream(&events,&ne),*lf=open_memstream(&logs,&nl);
            if(ef){dm_diag_write_events(ef,snapshot);if(fclose(ef)){free(events);events=NULL;}}if(lf){dm_diag_write_logs(lf,snapshot);if(fclose(lf)){free(logs);logs=NULL;}}
            uint64_t first=cutoff;for(size_t i=0;i<snapshot->event_count;i++)first=MIN(first,snapshot->events[i].ns);
            double seconds=(cutoff-first)/1e9;
            char hw[128]={0};size_t hwlen=sizeof hw-1;sysctlbyname("hw.machine",hw,&hwlen,NULL,0);
            NSMutableDictionary *meta=[runtime mutableCopy];[meta addEntriesFromDictionary:@{@"created":@(date.timeIntervalSince1970),@"capture_monotonic_ns":@(cutoff),@"requested_history_seconds":@(requested),@"actual_history_seconds":@(seconds),@"screenshot_delay_ms":@((screenshotAt-cutoff)/1e6),@"screenshot_available":@(image!=nil),@"screenshot_error":failure?:@"",@"settings":settings,@"hardware":@(hw),@"model":UIDevice.currentDevice.model,@"os":NSProcessInfo.processInfo.operatingSystemVersionString,@"app_version":[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]?:@"",@"app_build":[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"]?:@"",@"session_event_drops":@(snapshot->event_drops),@"session_log_drop_bytes":@(snapshot->log_drops),@"session_event_overwrites":@(snapshot->event_overwrites),@"session_log_overwrites":@(snapshot->log_overwrites),@"event_count":@(snapshot->event_count),@"clock":@"mach_absolute_time, nanoseconds",@"schema":@{@"1":@"audio: id=output, a=requested_frames, b=pending_blocks, c=callback_ns, d=zero_filled_bytes",@"2":@"enqueue: id=frame, a=queue_wait_ns, b=period_ns, c=depth, d=ticket",@"3":@"present: id=frame, a=drawable_wait_ns, b=encode_wall_ns, c=target_ns, d=ticket",@"4":@"GPU submission: id=frame, a=GPU_start_ns, b=GPU_end_ns (submissions may overlap)",@"5":@"display: id=ticket, a=actual_present_ns, b=target_ns, c=frame",@"6":@"lifecycle: id=0..3 OS events, 10 pause, 11 resume; a=paused"}}];
            uint64_t firstLog=cutoff;for(size_t i=0;i<snapshot->log_count;i++)firstLog=MIN(firstLog,snapshot->logs[i].ns);
            meta[@"log_history_seconds"]=@((cutoff-firstLog)/1e9);
            meta[@"host_revision"]=[NSBundle.mainBundle objectForInfoDictionaryKey:@"DMSourceRevision"]?:@"unknown";
            meta[@"host_source_fingerprint"]=[NSBundle.mainBundle objectForInfoDictionaryKey:@"DMSourceFingerprint"]?:@"unknown";
            meta[@"ring_capacity_bytes"]=@(sizeof(dm_diag_event)*DM_DIAG_EVENTS+sizeof(dm_diag_log)*DM_DIAG_LOGS);
            dm_diag_snapshot_free(snapshot);
            NSMutableDictionary *files=[NSMutableDictionary dictionary];if(events)files[@"timings.csv"]=[NSData dataWithBytesNoCopy:events length:ne freeWhenDone:YES];if(logs)files[@"logs.txt"]=[NSData dataWithBytesNoCopy:logs length:nl freeWhenDone:YES];
            NSData *shot=jpeg(image,1280,.76),*thumb=jpeg(image,240,.72);if(shot)files[@"screenshot.jpg"]=shot;if(thumb)files[@"thumbnail.jpg"]=thumb;
            meta[@"screenshot_available"]=@(shot!=nil);if(image&&!shot)meta[@"screenshot_error"]=@"Screenshot JPEG encoding failed.";
            DuoDiagnosticCapture *capture=[DuoDiagnosticCapture new];capture.metadata=meta;capture.files=files;capture.note=@"";capture.seconds=seconds;capture.preview=thumb?[UIImage imageWithData:thumb]:shot?[UIImage imageWithData:shot]:nil;
            uint64_t actualUsed=[s->_store usedBytes];
            dispatch_async(dispatch_get_main_queue(),^{s.capturing=NO;if(s->_cancelCapture){changed();return;}if(!files[@"timings.csv"]||!files[@"logs.txt"]){[s message:L(@"無法擷取",@"Capture failed") body:L(@"無法準備診斷資料。",@"Could not prepare diagnostic data.")];return;}s.used=actualUsed;s->_pending=capture;[s presentPending];});
        }});
    });
}
- (void)savePending{
    if(!_pending||_capturing)return;_pending.note=_overlay.note;DuoDiagnosticCapture *capture=_pending;self.capturing=YES;_overlay.userInteractionEnabled=NO;changed();
    dispatch_async(_io,^{self->_store.limitBytes=limitBytes();NSError *e=nil;NSString *identifier=[self->_store saveFiles:capture.files metadata:capture.metadata note:capture.note error:&e];uint64_t used=[self->_store usedBytes];
        dispatch_async(dispatch_get_main_queue(),^{self.capturing=NO;self->_overlay.userInteractionEnabled=YES;self.used=used;if(identifier){self->_pending=nil;[self close:YES];[self refresh];}else if(e.code==EDQUOT){[self presentPending];}else{[self message:L(@"報告未儲存",@"Report not saved") body:e.localizedDescription];}});
    });
}
- (void)retry{if(_pending&&!_overlay&&!_capturing)[self request];}
- (BOOL)hasPending{return _pending!=nil;}
- (void)edit:(NSDictionary *)report{
    if(_exporting||_capturing)return;__weak typeof(self) ws=self;NSString *identifier=report[@"id"];
    UIImage *im=[UIImage imageWithContentsOfFile:[report[@"directory"] URLByAppendingPathComponent:@"thumbnail.jpg"].path];
    NSString *info=[NSString stringWithFormat:@"%@ · %.1f s · %@",when(report[@"created"]),[report[@"actual_history_seconds"] doubleValue],mb([report[@"bytes"] unsignedLongLongValue])];
    void (^saveThen)(void (^)(void))=^(void (^next)(void)){
        DuoDiagnosticManager *s=ws;DuoDiagnosticOverlay *editor=s->_overlay;NSString *note=editor.note;s.capturing=YES;editor.userInteractionEnabled=NO;changed();dispatch_async(s->_io,^{NSError *e=nil;s->_store.limitBytes=limitBytes();BOOL ok=[s->_store updateNote:note report:identifier error:&e];dispatch_async(dispatch_get_main_queue(),^{s.capturing=NO;editor.userInteractionEnabled=YES;if(ok){[s refresh];next();}else{s->_noteErrorEditor=editor;[s message:L(@"說明未儲存",@"Note not saved") body:e.localizedDescription];}});});
    };
    [self show:[[DuoDiagnosticOverlay alloc] initWithMode:@"detail" title:L(@"報告",@"Report") info:info body:nil image:im note:report[@"note"] actions:@[[self button:L(@"完成",@"Done") style:0 tap:^{saveThen(^{[ws close:NO];});}],[self button:L(@"分享",@"Share") style:3 tap:^{saveThen(^{[ws share:@[identifier]];});}],[self button:L(@"刪除",@"Delete") style:0 tap:^{[ws remove:@[identifier]];}]]]];
}
- (void)remove:(NSArray<NSString *> *)ids{
    if(!ids.count){[self message:L(@"請先選取報告",@"Select a report first") body:nil];return;}__weak typeof(self) ws=self;
    DuoDiagnosticOverlay *previous=_overlay;
    [self show:[[DuoDiagnosticOverlay alloc] initWithMode:@"delete" title:L(@"刪除這些報告？",@"Delete these reports?") info:[NSString stringWithFormat:L(@"%lu 份報告",@"%lu reports"),(unsigned long)ids.count] body:nil image:nil note:nil actions:@[[self button:L(@"保留報告",@"Keep reports") style:0 tap:^{if(previous)[ws show:previous];else[ws close:NO];}],[self button:L(@"刪除報告",@"Delete reports") style:3 tap:^{DuoDiagnosticManager *s=ws;s.capturing=YES;s->_overlay.userInteractionEnabled=NO;changed();dispatch_async(s->_io,^{NSError *e=nil;BOOL ok=[s->_store deleteReports:ids error:&e];uint64_t used=[s->_store usedBytes];dispatch_async(dispatch_get_main_queue(),^{s.capturing=NO;s.used=used;[s close:NO];[s refresh];if(!ok)[s message:L(@"無法刪除",@"Cannot delete reports") body:e.localizedDescription];else[s retry];});});}]]]];
}
- (void)share:(NSArray<NSString *> *)ids{
    if(_exporting)return;if(!ids.count){[self message:L(@"請先選取報告",@"Select a report first") body:nil];return;}self.exporting=YES;changed();
    dispatch_async(_io,^{NSError *e=nil;self->_store.limitBytes=limitBytes();NSURL *url=[self->_store exportReports:ids error:&e];dispatch_async(dispatch_get_main_queue(),^{
        if(!url){self.exporting=NO;[self message:L(@"無法分享",@"Cannot share reports") body:e.localizedDescription];changed();return;}
        UIActivityViewController *vc=[[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];UIViewController *host=[self host];
        vc.popoverPresentationController.sourceView=self->_overlay?:host.view;vc.popoverPresentationController.sourceRect=CGRectMake(host.view.bounds.size.width/2,host.view.bounds.size.height/2,1,1);
        vc.completionWithItemsHandler=^(UIActivityType type,BOOL done,NSArray *items,NSError *error){(void)type;(void)done;(void)items;(void)error;dispatch_async(self->_io,^{[self->_store clearExport];dispatch_async(dispatch_get_main_queue(),^{self.exporting=NO;changed();});});};
        if(host)[host presentViewController:vc animated:YES completion:nil];else{self.exporting=NO;dispatch_async(self->_io,^{[self->_store clearExport];});changed();}
    });});
}
- (void)number:(BOOL)storage{
    __weak typeof(self) ws=self;NSString *title=storage?L(@"報告儲存上限",@"Report storage limit"):L(@"保留時間",@"History");
    DuoDiagnosticOverlay *v=[[DuoDiagnosticOverlay alloc] initWithMode:@"number" title:title info:nil body:nil image:nil note:nil actions:@[[self button:L(@"取消",@"Cancel") style:0 tap:^{[ws close:NO];}],[self button:L(@"確定",@"OK") style:3 tap:^{DuoDiagnosticManager *s=ws;NSString *raw=s->_overlay.note;NSScanner *sc=[NSScanner scannerWithString:raw];NSInteger n=0;if(![sc scanInteger:&n]||!sc.isAtEnd||n<(storage?5:10)||n>(storage?500:300)){[s message:L(@"數值無效",@"Invalid amount") body:storage?@"5–500 MB":@"10–300 s"];return;}[prefs() setInteger:n forKey:storage?@"DiagnosticLimitMB":@"DiagnosticHistory"];[s close:NO];changed();if(storage)[s retry];}]]];
    [self show:v];[v focusNumber:[NSString stringWithFormat:@"%u",storage?limitMB():history()] unit:storage?@"MB":@"s"];
}
@end

BOOL duo_diagnostics_busy(void){DuoDiagnosticManager *m=DuoDiagnosticManager.shared;return m.capturing||m.exporting||(!recording()&&!m.hasPending);}
void duo_diagnostics_request(void){if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{duo_diagnostics_request();});return;}[DuoDiagnosticManager.shared request];}
void duo_diagnostics_refresh(void){[DuoDiagnosticManager.shared refresh];}

@interface DuoDiagnosticRow:DuoPill
@property(nonatomic,strong) UIImageView *picture;
@property(nonatomic,strong) UIButton *check;
@end
@implementation DuoDiagnosticRow
- (void)layoutSubviews{[super layoutSubviews];CGFloat h=self.bounds.size.height,w=self.bounds.size.width,u=h/96;_check.frame=CGRectMake(16*u,(h-40*u)/2,32*u,32*u);CGFloat x=55*u;if(w>420){_picture.hidden=NO;_picture.frame=CGRectMake(x,15*u,72*u,54*u);x+=85*u;}else _picture.hidden=YES;self.title.frame=CGRectMake(x,12*u,w-x-22*u,42*u);self.title.textAlignment=NSTextAlignmentLeft;self.title.numberOfLines=2;self.sub.frame=CGRectMake(x,56*u,w-x-22*u,22*u);self.sub.textAlignment=NSTextAlignmentLeft;}
@end

UIView *duo_diagnostics_settings(CGFloat width,CGFloat u,void (^refresh)(void)){
    DuoDiagnosticManager *m=DuoDiagnosticManager.shared;UIView *page=[[UIView alloc] initWithFrame:CGRectMake(0,0,width,1)];__block CGFloat y=0;
    void (^label)(NSString *,CGFloat,UIFontWeight)=^(NSString *s,CGFloat size,UIFontWeight weight){UILabel *v=text(s,size*u,weight);[page addSubview:v];y+=fit(v,0,y,width)+12*u;};
    void (^pair)(NSString *,NSString *,NSString *,BOOL,void (^)(BOOL))=^(NSString *name,NSString *a,NSString *b,BOOL first,void (^set)(BOOL)){
        UILabel *l=text(name,17*u,UIFontWeightSemibold);CGFloat bw=MAX(66*u,width*.135),gap=10*u,left=width-2*bw-gap;CGFloat lh=fit(l,0,y,MAX(90,left-12));[page addSubview:l];CGFloat h=MAX(57*u,lh);
        for(int i=0;i<2;i++){DuoPill *p=duo_make_pill(i?b:a,nil,first==!i?1:0,u,^{set(i==0);refresh();});p.frame=CGRectMake(left+i*(bw+gap),y,bw,55*u);[page addSubview:p];}y+=h+16*u;
    };
    label(L(@"錄製",@"Recorder"),21,UIFontWeightHeavy);
    pair(L(@"記錄最近的資料",@"Record recent history"),L(@"開",@"On"),L(@"關",@"Off"),recording(),^(BOOL on){[prefs() setBool:on forKey:@"DiagnosticRecording"];dm_diag_configure(on);changed();});
    pair(L(@"畫面上的擷取鍵",@"On-screen capture button"),L(@"顯示",@"Show"),L(@"隱藏",@"Hide"),duo_diagnostics_button_visible(),^(BOOL on){[prefs() setBool:on forKey:@"DiagnosticButton"];changed();});
    int cols=width>=560?2:1;CGFloat gap=18*u,cw=(width-gap*(cols-1))/cols;
    for(int i=0;i<2;i++){CGFloat x=(i%cols)*(cw+gap),yy=y+(i/cols)*75*u;UILabel *l=text(i?L(@"報告儲存上限",@"Report storage limit"):L(@"保留時間",@"History"),16*u,UIFontWeightSemibold);l.frame=CGRectMake(x,yy,cw-126*u,55*u);[page addSubview:l];NSString *amount=[NSString stringWithFormat:i?@"%u MB":@"%u s",i?limitMB():history()];DuoPill *p=duo_make_pill(amount,nil,0,u,^{[m number:i!=0];});p.frame=CGRectMake(x+cw-116*u,yy,116*u,55*u);[page addSubview:p];}
    y+=((2+cols-1)/cols)*75*u+8*u;
    label(L(@"已儲存的報告",@"Saved reports"),21,UIFontWeightHeavy);
    label(m.used==UINT64_MAX?L(@"無法使用報告儲存空間",@"Report storage unavailable"):[NSString stringWithFormat:L(@"已用 %.1f / %u MB",@"%.1f / %u MB used"),m.used/1000000.0,limitMB()],14,UIFontWeightSemibold);
    NSUInteger count=MIN(m.visibleCount,m.reports.count);
    for(NSUInteger i=0;i<count;i++){
        NSDictionary *r=m.reports[i];NSString *identifier=r[@"id"],*note=r[@"note"];
        DuoDiagnosticRow *row=[DuoDiagnosticRow new];row.depth=4*u;row.title.text=note.length?note:L(@"尚無說明",@"No description yet");row.title.font=duo_font(17*u,UIFontWeightBold);row.sub.hidden=NO;row.sub.font=duo_font(12*u,UIFontWeightSemibold);row.sub.text=[NSString stringWithFormat:@"%@ · %.1f s · %@",when(r[@"created"]),[r[@"actual_history_seconds"] doubleValue],mb([r[@"bytes"] unsignedLongLongValue])];row.accessibilityLabel=[NSString stringWithFormat:@"%@, %@",row.title.text,row.sub.text];row.accessibilityTraits=UIAccessibilityTraitButton;
        row.picture=[[UIImageView alloc] initWithImage:[UIImage imageWithContentsOfFile:[r[@"directory"] URLByAppendingPathComponent:@"thumbnail.jpg"].path]];row.picture.contentMode=UIViewContentModeScaleAspectFit;[row addSubview:row.picture];
        row.check=[UIButton buttonWithType:UIButtonTypeSystem];BOOL selected=[m.selected containsObject:identifier];[row.check setImage:[UIImage systemImageNamed:selected?@"checkmark.square.fill":@"square"] forState:UIControlStateNormal];row.check.tintColor=duo_rgb(DUO_NAVY);row.check.accessibilityLabel=L(@"選取報告",@"Select report");
        void (^select)(void)=^{if([m.selected containsObject:identifier])[m.selected removeObject:identifier];else[m.selected addObject:identifier];refresh();};
        [row.check addAction:[UIAction actionWithHandler:^(UIAction *a){(void)a;select();}] forControlEvents:UIControlEventTouchUpInside];[row addSubview:row.check];
        row.accessibilityCustomActions=@[[[UIAccessibilityCustomAction alloc] initWithName:L(@"切換選取",@"Toggle selection") actionHandler:^BOOL(UIAccessibilityCustomAction *a){(void)a;select();return YES;}]];
        [row addAction:[UIAction actionWithHandler:^(UIAction *a){(void)a;[m edit:r];}] forControlEvents:UIControlEventTouchUpInside];row.frame=CGRectMake(0,y,width,96*u);[page addSubview:row];y+=110*u;
    }
    if(!count)label(L(@"還沒有報告。",@"No saved reports."),16,UIFontWeightSemibold);
    if(count<m.reports.count){DuoPill *more=duo_make_pill(L(@"顯示更多",@"Show more"),nil,0,u,^{m.visibleCount+=20;refresh();});more.frame=CGRectMake(0,y,width,55*u);[page addSubview:more];y+=70*u;}
    CGFloat bw=(width-14*u)/2;
    DuoPill *del=duo_make_pill(L(@"刪除所選",@"Delete selected"),nil,0,u,^{[m remove:m.selected.allObjects];}),*share=duo_make_pill(L(@"分享所選",@"Share selected"),nil,2,u,^{[m share:m.selected.allObjects];});
    del.frame=CGRectMake(0,y,bw,57*u);share.frame=CGRectMake(bw+14*u,y,bw,57*u);del.enabled=share.enabled=!m.capturing&&!m.exporting;[page addSubview:del];[page addSubview:share];y+=73*u;
    page.frame=CGRectMake(0,0,width,y);return page;
}
