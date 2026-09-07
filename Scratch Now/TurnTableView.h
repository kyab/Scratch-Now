//
//  TurnTableView.h
//  Fluent Scratch
//
//  Created by kyab on 2017/05/08.
//  Copyright © 2017年 kyab. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "RingBuffer.h"

#define TOUCH_TARGET_SAMPLE_CAP 128

@protocol TurnTableDelegate <NSObject>
@optional
-(void)turnTableSpeedRateChanged;
@end


@interface TurnTableView : NSView{
    BOOL _isPlatterTouchingByMouseEvents;
    double _currentRad;
    double _currentRadPlay;
    
    RingBuffer *_ring;
    
    CGFloat _startOffsetRad;
    
    NSTimer *_timer;
    NSTimer *_timer2;   //scratch monitor
    NSTimer *_timerLog;
    
    NSTimeInterval _prevSec;
    double _prevRad;
    BOOL _prevRadValid;
    
    CGFloat _prevX;
    CGFloat _prevY;
    
    double _speedRateByMouseEvents;
    double _history[10];
    int _historyCount;

    double _speedRateByTouchEvents;
    double _touchSpeedTarget;
    BOOL _isPlatterTouchingByTouchEvents;
    BOOL _isCoastingForTouchEvent;
    NSTimeInterval _prevTouchEventSec;
    BOOL _prevTouchEventSecValid;
    double _prevTouchCentroidY;
    BOOL _touchSpeedSmoothedValid;
    NSTimeInterval _prevTouchTimerSec;
    BOOL _prevTouchTimerSecValid;
    NSTimeInterval _touchTargetSampleSec[TOUCH_TARGET_SAMPLE_CAP];
    double _touchTargetSampleV[TOUCH_TARGET_SAMPLE_CAP];
    int _touchTargetSampleCount;
    
    id<TurnTableDelegate> _delegate;
}

-(void)setDelegate:(id<TurnTableDelegate>)delegate;
-(void)setRingBuffer:(RingBuffer *)ring;
-(void)start;
-(void)stop;
-(double)speedRate;
-(void)setSpeedRate:(float)speedRate;
-(Boolean)isUnderManualControl;
@end
