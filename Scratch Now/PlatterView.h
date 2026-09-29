//
//  PlatterView.h
//  Scratch Now
//
//  Created by kyab on 2017/05/08.
//  Copyright © 2017年 kyab. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "TurnTable.h"

#define TOUCH_TARGET_SAMPLE_CAP 128
#define MOUSE_SPEED_HISTORY_NUM 10

@class PlatterView;

@protocol PlatterViewDelegate <NSObject>
-(void)platterViewScratchBegan:(PlatterView *)platterView;
-(void)platterView:(PlatterView *)platterView scratchSpeedChanged:(double)speedRate;
-(void)platterView:(PlatterView *)platterView scratchEndedWithReleaseSpeed:(double)speedRate;
@end

// Whichever device starts a scratch owns it until that scratch ends; the other
// device is ignored meanwhile.
typedef NS_ENUM(NSInteger, PlatterInputDevice) {
    PlatterInputDeviceNone,
    PlatterInputDeviceMouse,
    PlatterInputDeviceTouch,
};

@interface PlatterView : NSView{
    __weak id<PlatterViewDelegate> _delegate;
    TurnTable *_turnTable;

    double _currentRad;
    PlatterInputDevice _activeDevice;

    NSTimer *_redrawTimer;
    NSTimer *_mouseDragTimer;
    NSTimer *_touchTimer;

    BOOL _isPlatterTouchingByMouseEvents;
    CGFloat _startOffsetRad;
    NSTimeInterval _prevSec;
    double _prevRad;
    double _speedRateByMouseEvents;
    double _history[MOUSE_SPEED_HISTORY_NUM];
    int _historyCount;

    BOOL _isPlatterTouchingByTouchEvents;
    double _speedRateByTouchEvents;
    double _touchSpeedTarget;
    NSTimeInterval _prevTouchEventSec;
    BOOL _prevTouchEventSecValid;
    double _prevTouchCentroidY;
    BOOL _touchSpeedSmoothedValid;
    NSTimeInterval _prevTouchTimerSec;
    BOOL _prevTouchTimerSecValid;
    NSTimeInterval _touchTargetSampleSec[TOUCH_TARGET_SAMPLE_CAP];
    double _touchTargetSampleV[TOUCH_TARGET_SAMPLE_CAP];
    int _touchTargetSampleCount;
}

-(void)setDelegate:(id<PlatterViewDelegate>)delegate;
-(void)setTurnTable:(TurnTable *)turnTable;
@end
