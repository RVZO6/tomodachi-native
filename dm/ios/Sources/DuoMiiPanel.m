// iPad／iPhone 原生 Mii 檔案選擇器與替換確認；預覽區固定高度，選檔不推移居民按鍵。
// Native iPad/iPhone Mii picker and replacement confirmation; a fixed preview height prevents file selection from moving the islander buttons.
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "duo_shell.h"
#include "duo_mii.h"

static NSString *ML(NSString *zh,NSString *en) { return [NSLocale.preferredLanguages.firstObject hasPrefix:@"zh"]?zh:en; }
static UIImage *mii_placeholder(void) {
    static UIImage *image;static dispatch_once_t once;dispatch_once(&once,^{
        UIImage *source=duo_asset(@"mii_placeholder");
        if(source && CGSizeEqualToSize(source.size,CGSizeMake(256,256))){
            // 遊戲的備用圖有上方留白；在套用方向後裁到可見人像，不能把留白也當成頭像高度。
            // The game's fallback has top padding; crop the oriented image to its visible silhouette instead of including padding in the avatar height.
            UIGraphicsImageRendererFormat *f=[UIGraphicsImageRendererFormat defaultFormat];f.scale=1;
            image=[[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(113,177) format:f] imageWithActions:^(UIGraphicsImageRendererContext *c){(void)c;[source drawInRect:CGRectMake(-72,-79,256,256)];}];
        }
        if(!image)image=[[UIImage systemImageNamed:@"person.fill"] imageWithTintColor:duo_rgb(0x777777) renderingMode:UIImageRenderingModeAlwaysOriginal];
    });return image;
}
// 沒有島民時的空白頁：遊戲的備用人像排成三人一組，站在淺色地面上，旁邊幾顆白色閃光。
// Empty state with no islanders: three of the game's fallback silhouettes in a group on a pale ground, with a few white sparkles.
// 地面畫在人像前面，蓋住備用圖裁切後的底邊；兩旁的人像染成白色。
// The ground is drawn in front of the figures to hide the cropped lower edge of the fallback image; the two side figures are tinted white.
@interface DuoMiiEmpty : UIView
@property(nonatomic) CGFloat unit;
@end
@implementation DuoMiiEmpty { UIImageView *_fig[3];CAShapeLayer *_ground,*_spark;UILabel *_title,*_body; }
- (instancetype)init {
    if((self=[super initWithFrame:CGRectZero])){
        _unit=1;_ground=[CAShapeLayer layer];_ground.fillColor=duo_rgb(DUO_WAVE).CGColor;[self.layer addSublayer:_ground];
        _spark=[CAShapeLayer layer];_spark.fillColor=UIColor.whiteColor.CGColor;[self.layer addSublayer:_spark];
        for(int i=0;i<3;i++){_fig[i]=[[UIImageView alloc] initWithImage:i==1?mii_placeholder():[mii_placeholder() imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];_fig[i].tintColor=UIColor.whiteColor;_fig[i].contentMode=UIViewContentModeScaleAspectFit;_fig[i].layer.anchorPoint=CGPointMake(.5,1);}
        [self addSubview:_fig[0]];[self addSubview:_fig[2]];[self addSubview:_fig[1]];_fig[0].alpha=_fig[2].alpha=.8;_ground.zPosition=1;
        _title=[UILabel new];_title.text=ML(@"島上還沒有島民",@"No islanders yet");_title.textColor=duo_rgb(DUO_NAVY);_title.textAlignment=NSTextAlignmentCenter;[self addSubview:_title];
        _body=[UILabel new];_body.text=ML(@"在遊戲裡建立的島民會出現在這裡。",@"Islanders you create in the game appear here.");_body.textColor=[duo_rgb(DUO_NAVY) colorWithAlphaComponent:.72];_body.textAlignment=NSTextAlignmentCenter;_body.numberOfLines=0;[self addSubview:_body];
        self.isAccessibilityElement=YES;self.accessibilityLabel=[NSString stringWithFormat:@"%@. %@",_title.text,_body.text];
    }return self;
}
static void star(CGMutablePathRef p,CGFloat x,CGFloat y,CGFloat r) {   // 四角閃光 | a four-point sparkle
    CGFloat k=r*.28;CGPathMoveToPoint(p,NULL,x,y-r);CGPathAddQuadCurveToPoint(p,NULL,x+k,y-k,x+r,y);CGPathAddQuadCurveToPoint(p,NULL,x+k,y+k,x,y+r);
    CGPathAddQuadCurveToPoint(p,NULL,x-k,y+k,x-r,y);CGPathAddQuadCurveToPoint(p,NULL,x-k,y-k,x,y-r);CGPathCloseSubpath(p);
}
- (void)layoutSubviews {
    [super layoutSubviews];CGFloat u=_unit,w=self.bounds.size.width,cx=w/2,base=150*u,aspect=113.0/177;
    CGPathRef g=CGPathCreateWithEllipseInRect(CGRectMake(cx-165*u,base-12*u,330*u,36*u),NULL);_ground.path=g;CGPathRelease(g);
    CGMutablePathRef sp=CGPathCreateMutable();star(sp,cx-138*u,44*u,11*u);star(sp,cx+132*u,30*u,14*u);star(sp,cx+156*u,86*u,7*u);star(sp,cx-112*u,96*u,6*u);_spark.path=sp;CGPathRelease(sp);
    for(int i=0;i<3;i++){CGFloat h=(i==1?124:96)*u,dx=(i-1)*78*u;_fig[i].transform=CGAffineTransformIdentity;_fig[i].bounds=CGRectMake(0,0,h*aspect,h);_fig[i].center=CGPointMake(cx+dx,base+(i==1?4:-2)*u);_fig[i].transform=CGAffineTransformMakeRotation((i-1)*.12);}
    _title.font=duo_font(21*u,UIFontWeightHeavy);_title.frame=CGRectMake(0,base+26*u,w,30*u);
    _body.font=duo_font(15*u,UIFontWeightSemibold);_body.frame=CGRectMake(0,base+58*u,w,40*u);
}
@end

@interface DuoMiiPanel () <UIDocumentPickerDelegate>
@end
@implementation DuoMiiPanel {
    BOOL _exportMode;NSInteger _stage;CGFloat _unit;NSArray<NSDictionary *> *_roster;NSDictionary *_input,*_target;
    DuoPill *_choose,*_replace,*_goBack,*_yes,*_cancel,*_cancelQueued,*_settings;
    UIView *_preview,*_identity,*_rosterBody;CAGradientLayer *_pale;UIScrollView *_rosterScroll;
    UIImageView *_head;UILabel *_name,*_file,*_question,*_notice;NSArray<DuoPill *> *_targets;DuoMiiEmpty *_empty;
    NSString *_message;NSURL *_exportURL;
}
- (BOOL)exportMode { return _exportMode; }
- (DuoPill *)key:(NSString *)title style:(int)style action:(void (^)(void))action {
    DuoPill *p=[DuoPill new];p.style=style;p.title.text=title;p.accessibilityLabel=title;
    if(action)[p addAction:[UIAction actionWithHandler:^(UIAction *a){(void)a;action();}] forControlEvents:UIControlEventTouchUpInside];[self addSubview:p];return p;
}
- (UILabel *)label {
    UILabel *p=[UILabel new];p.textColor=duo_rgb(DUO_NAVY);p.textAlignment=NSTextAlignmentCenter;p.numberOfLines=0;[self addSubview:p];return p;
}
- (instancetype)initWithExportMode:(BOOL)mode {
    if((self=[super initWithFrame:CGRectZero])){
        _exportMode=mode;_unit=1;__weak DuoMiiPanel *ws=self;
        _choose=[self key:ML(@"從「檔案」選取",@"Choose from Files") style:PILL_PLAIN action:^{[ws chooseFile];}];
        _preview=[UIView new];[self addSubview:_preview];_pale=[CAGradientLayer layer];[_preview.layer addSublayer:_pale];
        _identity=[UIView new];[_preview addSubview:_identity];_identity.isAccessibilityElement=YES;
        _head=[[UIImageView alloc] initWithImage:mii_placeholder()];_head.contentMode=UIViewContentModeScaleAspectFit;[_identity addSubview:_head];
        _name=[UILabel new];_name.textAlignment=NSTextAlignmentLeft;_name.adjustsFontSizeToFitWidth=YES;_name.minimumScaleFactor=.6;_name.textColor=duo_rgb(DUO_NAVY);[_identity addSubview:_name];
        _file=[UILabel new];_file.textAlignment=NSTextAlignmentLeft;_file.lineBreakMode=NSLineBreakByTruncatingMiddle;_file.textColor=[duo_rgb(DUO_NAVY) colorWithAlphaComponent:.72];[_identity addSubview:_file];
        _replace=[self key:mode?ML(@"匯出",@"Export"):ML(@"替換",@"Replace") style:PILL_CONFIRM action:^{[ws replacePressed];}];[_preview addSubview:_replace];
        _question=[self label];_notice=[self label];_notice.textColor=duo_rgb(0xF2660D);_notice.accessibilityTraits=UIAccessibilityTraitStaticText;
        _empty=[DuoMiiEmpty new];[self addSubview:_empty];
        _rosterScroll=[UIScrollView new];_rosterScroll.showsHorizontalScrollIndicator=NO;_rosterScroll.alwaysBounceVertical=NO;[self addSubview:_rosterScroll];_rosterBody=[UIView new];[_rosterScroll addSubview:_rosterBody];
        NSString *why=nil;_roster=duo_mii_roster(&why)?:@[];if(why)_message=why;
        NSMutableArray *targets=[NSMutableArray array];
        for(NSDictionary *row in _roster){
            DuoPill *p=[DuoPill new];p.title.text=row[@"name"];p.sub.hidden=NO;p.sub.text=[NSString stringWithFormat:ML(@"位置 %02d",@"Slot %02d"),[row[@"slot"] intValue]];p.portraitImage=mii_placeholder();p.title.minimumScaleFactor=.55;p.accessibilityLabel=[NSString stringWithFormat:@"%@, %@",p.title.text,p.sub.text];
            [p addAction:[UIAction actionWithHandler:^(UIAction *a){(void)a;DuoMiiPanel *s=ws;if(!s)return;s->_target=row;s->_message=nil;[s update:NO];UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,row[@"name"]);}] forControlEvents:UIControlEventTouchUpInside];[_rosterBody addSubview:p];[targets addObject:p];
        }_targets=targets;
        _goBack=[self key:ML(@"返回",@"Back") style:PILL_PLAIN action:^{DuoMiiPanel *s=ws;if(s.back)s.back();}];
        _yes=[self key:mode?ML(@"匯出 Mii",@"Export Mii"):ML(@"替換 Mii",@"Replace Mii") style:PILL_CONFIRM action:^{[ws confirm];}];
        _cancel=[self key:ML(@"取消",@"Cancel") style:PILL_PLAIN action:^{DuoMiiPanel *s=ws;if(!s)return;s->_stage=0;s->_message=nil;[s update:YES];}];
        _cancelQueued=[self key:ML(@"取消匯入",@"Cancel Import") style:PILL_PLAIN action:^{DuoMiiPanel *s=ws;if(!s)return;duo_save_set_pending(nil);s->_stage=0;s->_message=ML(@"已取消，存檔沒有變。",@"Cancelled. Your save is unchanged.");[s update:YES];}];
        _settings=[self key:ML(@"返回設定",@"Back to Settings") style:PILL_CONFIRM action:^{DuoMiiPanel *s=ws;if(s.back)s.back();}];
        [self update:NO];
    }return self;
}
- (void)update:(BOOL)top {
    [self setNeedsLayout];[self layoutIfNeeded];if(top&&self.changed)self.changed(YES);
}
- (void)chooseFile {
    UIViewController *vc=self.window.rootViewController;while(vc.presentedViewController)vc=vc.presentedViewController;if(!vc)return;
    UTType *t=[UTType typeWithIdentifier:@"org.nxnative.sharemii.ltd"]?:[UTType typeWithFilenameExtension:@"ltd"]?:UTTypeData;
    UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[t] asCopy:YES];picker.allowsMultipleSelection=NO;picker.delegate=self;[vc presentViewController:picker animated:YES completion:nil];
}
- (void)replacePressed {
    if(!_exportMode&&!_input){_message=ML(@"請先選取一份 Mii 檔案。",@"Choose a Mii file first.");[self update:NO];return;}
    if(!_target){_message=_roster.count?ML(@"請選擇要替換的島民。",@"Choose an islander first."):ML(@"請先在遊戲裡建立一位島民。",@"Create an islander in the game first.");[self update:NO];UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,_message);return;}
    _stage=1;_message=nil;[self update:YES];
}
- (void)confirm {
    NSString *why=nil;
    if(_exportMode){
        NSURL *url=duo_mii_export(_target,&why);if(!url){_message=why;[self update:NO];return;}
        UIViewController *vc=self.window.rootViewController;while(vc.presentedViewController)vc=vc.presentedViewController;
        if(!vc){[NSFileManager.defaultManager removeItemAtURL:url.URLByDeletingLastPathComponent error:nil];return;}
        _exportURL=url;UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc] initForExportingURLs:@[url] asCopy:YES];picker.delegate=self;[vc presentViewController:picker animated:YES completion:nil];return;
    }
    if(!duo_mii_queue(_input,_target,&why)){_message=why;[self update:NO];UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,why);return;}
    _stage=2;_message=nil;[self update:YES];UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,ML(@"Mii 匯入已排程，下次開啟遊戲時生效。",@"Mii import queued for the next launch."));
}
- (void)documentPicker:(UIDocumentPickerViewController *)picker didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)picker;
    if(_exportURL){[NSFileManager.defaultManager removeItemAtURL:_exportURL.URLByDeletingLastPathComponent error:nil];_exportURL=nil;_stage=0;_message=ML(@"已匯出到「檔案」。",@"Exported to Files.");[self update:YES];return;}
    if(!urls.count)return;NSString *why=nil;NSDictionary *input=duo_mii_read_file(urls.firstObject,&why);
    _input=nil;_target=nil;_stage=0;
    if(input){_input=input;_message=nil;}else _message=why;
    // 選檔只更新固定預覽區，不重建外層頁面，也不改動捲動位置。
    // File selection updates only the fixed preview area: do not rebuild the outer page or change its scroll position.
    [self update:NO];if(why)UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,why);
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)picker {
    (void)picker;if(_exportURL){[NSFileManager.defaultManager removeItemAtURL:_exportURL.URLByDeletingLastPathComponent error:nil];_exportURL=nil;}[self update:NO];
}
- (CGFloat)heightForWidth:(CGFloat)width unit:(CGFloat)unit {
    (void)width;_unit=unit;return (_stage?430:!_roster.count?(_message?420:360):(_exportMode?432:504))*unit;
}
- (void)layoutSubviews {
    [super layoutSubviews];CGFloat u=_unit,w=self.bounds.size.width,gap=14*u,rowH=68*u;
    BOOL choosing=_stage==0,ready=_exportMode?_target!=nil:_input!=nil;
    BOOL empty=!_roster.count;
    _choose.hidden=!choosing||_exportMode||empty;_rosterScroll.hidden=!choosing||empty;_empty.hidden=!choosing||!empty;_question.hidden=choosing&&empty;_replace.hidden=!choosing;_goBack.hidden=!choosing;
    _yes.hidden=_cancel.hidden=_stage!=1;_cancelQueued.hidden=_settings.hidden=_stage!=2;
    NSArray *keys=@[_choose,_replace,_goBack,_yes,_cancel,_cancelQueued,_settings];for(DuoPill *p in keys){p.depth=4*u;p.title.font=duo_font(19*u,UIFontWeightHeavy);}
    for(NSUInteger i=0;i<_targets.count;i++){DuoPill *p=_targets[i];NSDictionary *row=_roster[i];BOOL picked=[row[@"slot"] isEqual:_target[@"slot"]];p.style=picked?PILL_PICKED:PILL_PLAIN;p.depth=4*u;p.title.font=duo_font(17*u,UIFontWeightHeavy);p.sub.font=duo_font(11*u,UIFontWeightSemibold);p.accessibilityTraits=UIAccessibilityTraitButton|(picked?UIAccessibilityTraitSelected:0);}
    _question.font=duo_font(21*u,UIFontWeightHeavy);_notice.font=duo_font(14*u,UIFontWeightBold);
    CGFloat y=0;
    if(choosing&&empty){
        // 沒有島民：只顯示空白頁插圖、需要時的錯誤和返回鍵。
        // No islanders: show only the empty-state picture, an error when there is one, and Back.
        _preview.hidden=YES;_empty.unit=u;_empty.frame=CGRectMake(0,16*u,w,260*u);[_empty setNeedsLayout];y=284*u;
        _notice.text=_message;_notice.frame=CGRectMake(0,y,w,_message?58*u:0);y+=_message?64*u:0;
        _goBack.frame=CGRectMake(0,y,MIN(w,190*u),56*u);
    }else if(choosing){
        _choose.frame=CGRectMake((w-MIN(w,380*u))/2,0,MIN(w,380*u),60*u);
        y=_exportMode?0:72*u;
        _preview.frame=CGRectMake(0,y,w,100*u);y+=112*u;_preview.hidden=!ready;
        _question.text=_exportMode?ML(@"想匯出哪位島民？",@"Who would you like to export?"):ML(@"想替換哪位島民？",@"Who would you like to replace?");_question.frame=CGRectMake(0,y,w,32*u);y+=34*u;
        y+=6*u;
        int cols=w>=480*u?2:1;CGFloat cw=(w-gap*(cols-1))/cols;int rows=(int)(_roster.count+cols-1)/cols;
        CGFloat visible=MAX(rowH,MIN(rows,2)*(rowH+gap)-gap);
        _rosterScroll.frame=CGRectMake(0,y,w,visible);_rosterBody.frame=CGRectMake(0,0,w,MAX(visible,rows*(rowH+gap)-gap));
        for(NSUInteger i=0;i<_targets.count;i++)_targets[i].frame=CGRectMake((i%cols)*(cw+gap),(i/cols)*(rowH+gap),cw,rowH);
        _rosterScroll.contentSize=_rosterBody.bounds.size;y+=visible+12*u;
        _notice.text=_message?:(_exportMode?ML(@"匯出不會改動島上的資料。",@"Exporting does not change your island."):ML(@"只有選中的島民會被替換；匯入前會先備份。",@"Only the selected islander is replaced. A backup is made before import."));_notice.frame=CGRectMake(0,y,w,58*u);y+=64*u;
        _goBack.frame=CGRectMake(0,y,MIN(w,190*u),56*u);
    }else{
        _question.text=_stage==2?ML(@"Mii 匯入已排程。",@"Mii import queued."):_exportMode?ML(@"要匯出這位 Mii 嗎？",@"Export this Mii?"):[NSString stringWithFormat:ML(@"要替換 %@ 嗎？",@"Replace %@?"),_target[@"name"]?:@""];
        _question.frame=CGRectMake(0,16*u,w,60*u);_preview.hidden=NO;_preview.frame=CGRectMake(0,88*u,w,100*u);_replace.hidden=YES;
        _notice.text=_message?:(_stage==2?ML(@"下次開啟遊戲時套用。備份會在換入存檔前建立。\n關閉遊戲前，請先儲存想保留的進度。",@"Applies next launch, after a verified backup.\nSave any progress you want to keep before closing."):_exportMode?ML(@"會建立一份 .ltd 檔案，島上的資料不會改變。",@"A .ltd file will be created. Your island is unchanged."):ML(@"只替換所選 Mii 的設計及個人設定。\n下次開啟前會備份；目前的存檔不動。",@"Replaces only the selected Mii's design and personal settings.\nQueued for next launch; the current save is unchanged."));
        _notice.frame=CGRectMake(0,210*u,w,95*u);CGFloat bw=MIN((w-gap)/2,250*u),x=(w-(bw*2+gap))/2;
        _cancel.frame=_cancelQueued.frame=CGRectMake(x,322*u,bw,64*u);_yes.frame=_settings.frame=CGRectMake(x+bw+gap,322*u,bw,64*u);
    }
    _pale.frame=_preview.bounds;UIColor *pale=duo_rgb(DUO_WAVE);_pale.colors=@[(id)[pale colorWithAlphaComponent:0].CGColor,(id)pale.CGColor,(id)pale.CGColor,(id)[pale colorWithAlphaComponent:0].CGColor];_pale.locations=@[@0,@.17,@.83,@1];_pale.startPoint=CGPointMake(0,.5);_pale.endPoint=CGPointMake(1,.5);
    // 兩個區域：頭像、名字、檔名同屬一個識別區，右邊才是獨立的替換鍵。
    // Two areas: portrait, name and filename form one identity group; Replace is the separate action on the right.
    CGFloat actionW=choosing?MIN(146*u,w*.3):0,identityW=w-(choosing?actionW+gap:0);
    _identity.frame=CGRectMake(0,0,identityW,100*u);_replace.frame=CGRectMake(identityW+gap,18*u,actionW,64*u);_replace.enabled=YES;
    NSString *name=_exportMode?_target[@"name"]:_input[@"name"],*filename=_exportMode?[name stringByAppendingString:@".ltd"]:_input[@"filename"];
    _name.text=name?:@"";_file.text=filename?:@"";_name.font=duo_font(24*u,UIFontWeightHeavy);_file.font=duo_font(12*u,UIFontWeightSemibold);
    CGFloat imageW=52*u,natural=MAX([_name.text sizeWithAttributes:@{NSFontAttributeName:_name.font}].width,[_file.text sizeWithAttributes:@{NSFontAttributeName:_file.font}].width);
    CGFloat textW=MIN(MAX(50*u,natural+4*u),MAX(50*u,identityW-imageW-24*u)),contentW=imageW+12*u+textW,x=(identityW-contentW)/2;
    _head.frame=CGRectMake(x,21*u,imageW,58*u);_name.frame=CGRectMake(x+imageW+12*u,21*u,textW,37*u);_file.frame=CGRectMake(x+imageW+12*u,59*u,textW,20*u);
    _identity.accessibilityLabel=[NSString stringWithFormat:@"%@, %@",name?:@"",filename?:@""];
}
@end
