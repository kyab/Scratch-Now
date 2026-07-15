//
//  AppController.h
//  Scratch Now
//
//  Created by kyab on 2021/06/19.
//

#import <Foundation/Foundation.h>
#import <Cocoa/Cocoa.h>
#import "AudioEngine.h"
#import "ScratchPipeline.h"
#import "TurnTableView.h"

NS_ASSUME_NONNULL_BEGIN

@interface AppController : NSObject <AudioEngineRebuildDelegate, TurnTableDelegate>{
    AudioEngine *_ae;
    ScratchPipeline *_pipeline;
    __weak IBOutlet TurnTableView *_turnTableView;
    __weak IBOutlet NSSlider *_sliderDry;
    __weak IBOutlet NSButton *_btnStop;

    NSTimer *_tableStopTimer;
}

-(void)terminate;


@end

NS_ASSUME_NONNULL_END
