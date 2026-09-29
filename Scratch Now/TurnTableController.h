//
//  TurnTableController.h
//  Scratch Now
//

#import <Cocoa/Cocoa.h>
#import "TurnTable.h"
#import "PlatterView.h"

NS_ASSUME_NONNULL_BEGIN

@interface TurnTableController : NSViewController <PlatterViewDelegate>{
    TurnTable *_turnTable;

    __weak IBOutlet PlatterView *_platterView;
    __weak IBOutlet NSButton *_btnStop;
    __weak IBOutlet NSButton *_btnFollow;
    __weak IBOutlet NSButton *_chkAutoFollow;
    __weak IBOutlet NSSlider *_sliderDry;
}

-(void)setTurnTable:(TurnTable *)turnTable;

@end

NS_ASSUME_NONNULL_END
