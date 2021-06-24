//
//  TurnTableView.h
//  Fluent Scratch
//
//  Created by kyab on 2017/05/08.
//  Copyright © 2017年 kyab. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "RingBuffer.h"

@protocol TurnTableDelegate <NSObject>
@optional
-(void)turnTableSpeedRateChanged;
@end


@interface TurnTableView : NSView{
    BOOL _pressing;
    double _currentRad;
    double _currentRadPlay;
    
    RingBuffer *_ring;
    
    CGFloat _startOffsetRad;
    
    NSTimer *_timer;
    NSTimer *_timer2;   //scratch monitor
    
    NSTimeInterval _prevSec;
    double _prevRad;
    BOOL _prevRadValid;
    
    CGFloat _prevX;
    CGFloat _prevY;
    
    double _speedRate;
    
    id<TurnTableDelegate> _delegate;
}

-(void)setDelegate:(id<TurnTableDelegate>)delegate;
-(void)setRingBuffer:(RingBuffer *)ring;
-(void)start;
-(void)stop;
-(double)speedRate;
-(void)setSpeedRate:(float)speedRate;
-(Boolean)isScratching;
@end
