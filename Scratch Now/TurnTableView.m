 //
//  TurnTableView.m
//  Fluent Scratch
//
//  Created by kyab on 2017/05/08.
//  Copyright © 2017年 kyab. All rights reserved.
//

#import "TurnTableView.h"

#define TOUCH_Y_PER_SEC_FOR_1X 1.0
#define TOUCH_CENTROID_Y_EPSILON 0.000001
#define TOUCH_SPEED_TAU_SEC 0.01
#define TOUCH_TARGET_IDLE_SEC 0.1
#define TOUCH_TARGET_WINDOW_SEC 0.1

// Match AppController Stop ramp from 1.0x: -0.02 / 10ms until < 0.01 (~0.5s).
// EMA |v|=1 -> 0.01 in 0.5s => tau = 0.5 / -ln(0.01). = 0.1086
#define TOUCH_COAST_TAU_SEC 0.1086

#define TOUCH_COAST_END_EPSILON 0.01
#define TOUCH_COAST_SKIP_EPSILON 0.55

static NSString *NSTouchPhaseDescription(NSTouchPhase phase) {
    switch (phase) {
        case NSTouchPhaseBegan: return [NSString stringWithFormat:@"NSTouchPhaseBegan(%lu)", (unsigned long)phase];
        case NSTouchPhaseMoved: return [NSString stringWithFormat:@"NSTouchPhaseMoved(%lu)", (unsigned long)phase];
        case NSTouchPhaseStationary: return [NSString stringWithFormat:@"NSTouchPhaseStationary(%lu)", (unsigned long)phase];
        case NSTouchPhaseEnded: return [NSString stringWithFormat:@"NSTouchPhaseEnded(%lu)", (unsigned long)phase];
        case NSTouchPhaseCancelled: return [NSString stringWithFormat:@"NSTouchPhaseCancelled(%lu)", (unsigned long)phase];
        default: return [NSString stringWithFormat:@"NSTouchPhase(%lu)", (unsigned long)phase];
    }
}

static NSTimeInterval sPrevTouchLogSec = 0;
static NSMutableDictionary *sTouchSimpleIds = nil;
static NSInteger sNextTouchSimpleId = 1;

static NSInteger SimpleTouchId(id identity) {
    if (!sTouchSimpleIds) {
        sTouchSimpleIds = [NSMutableDictionary dictionary];
    }
    NSNumber *existing = sTouchSimpleIds[identity];
    if (existing) {
        return existing.integerValue;
    }
    NSInteger simpleId = sNextTouchSimpleId++;
    sTouchSimpleIds[identity] = @(simpleId);
    return simpleId;
}

static void ForgetSimpleTouchId(id identity) {
    [sTouchSimpleIds removeObjectForKey:identity];
    if (sTouchSimpleIds.count == 0) {
        sNextTouchSimpleId = 1;
    }
}

@implementation TurnTableView


- (void)awakeFromNib{
    _currentRad = 28 * (M_PI / 180);
    _speedRateByMouseEvents = 1.0f;
    _speedRateByTouchEvents = 1.0f;
    _isCoastingForTouchEvent = NO;
    
    [self setAllowedTouchTypes:NSTouchTypeMaskDirect | NSTouchTypeMaskIndirect];
    
    _timer2 = [NSTimer scheduledTimerWithTimeInterval:0.01 target:self selector:@selector(onMouseDragTimer:) userInfo:nil repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:_timer2 forMode:NSRunLoopCommonModes];
    
    _timerLog = [NSTimer scheduledTimerWithTimeInterval:0.01 target:self selector:@selector(onLogTimer:) userInfo:nil repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:_timerLog forMode:NSRunLoopCommonModes];
}

- (void)start{
    if (!_timer){
        _timer = [NSTimer scheduledTimerWithTimeInterval:0.002 target:self selector:@selector(onUIUpdateTimer:) userInfo:nil repeats:YES];
        [[NSRunLoop currentRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
    }
}

-(void)stop{
    [_timer invalidate];
    _timer = nil;
}

-(double) baseRadS{
    return -33.3/60 * M_PI*2;
}

double rad2deg(double rad){
    return rad / M_PI * 180;
}

-(void)clearTouchTargetSamples{
    _touchTargetSampleCount = 0;
}

-(double)pushTouchTargetSample:(double)vRaw at:(NSTimeInterval)ts{
    while (_touchTargetSampleCount > 0 && (ts - _touchTargetSampleSec[0]) > TOUCH_TARGET_WINDOW_SEC){
        for (int i = 1; i < _touchTargetSampleCount; i++){
            _touchTargetSampleSec[i - 1] = _touchTargetSampleSec[i];
            _touchTargetSampleV[i - 1] = _touchTargetSampleV[i];
        }
        _touchTargetSampleCount--;
    }
    
    if (_touchTargetSampleCount == TOUCH_TARGET_SAMPLE_CAP){
        for (int i = 1; i < _touchTargetSampleCount; i++){
            _touchTargetSampleSec[i - 1] = _touchTargetSampleSec[i];
            _touchTargetSampleV[i - 1] = _touchTargetSampleV[i];
        }
        _touchTargetSampleCount--;
    }
    
    _touchTargetSampleSec[_touchTargetSampleCount] = ts;
    _touchTargetSampleV[_touchTargetSampleCount] = vRaw;
    _touchTargetSampleCount++;
    
    if (_touchTargetSampleCount == 1){
        return vRaw;
    }
    
    double num = 0.0;
    double den = 0.0;
    for (int i = 1; i < _touchTargetSampleCount; i++){
        double sampleDt = _touchTargetSampleSec[i] - _touchTargetSampleSec[i - 1];
        if (sampleDt <= 0.0){
            continue;
        }
        num += _touchTargetSampleV[i] * sampleDt;
        den += sampleDt;
    }
    if (den <= 0.0){
        return vRaw;
    }
    return num / den;
}

-(void)endTouchEventScratch{
    _isCoastingForTouchEvent = NO;
    _isPlatterTouchingByTouchEvents = NO;
    _speedRateByTouchEvents = 1.0;
    _touchSpeedTarget = 1.0;
    _prevTouchEventSecValid = NO;
    _touchSpeedSmoothedValid = NO;
    _prevTouchTimerSecValid = NO;
    [self clearTouchTargetSamples];
    [_delegate turnTableSpeedRateChanged];
}

-(void)beginCoastForTouchEvent{
    _isPlatterTouchingByTouchEvents = NO;
    _isCoastingForTouchEvent = YES;
    _touchSpeedTarget = 0.0;
    _prevTouchEventSecValid = NO;
    [self clearTouchTargetSamples];
    [_delegate turnTableSpeedRateChanged];
}

-(void)onLogTimer:(NSTimer *)t{
    NSTimeInterval nowSec = [NSProcessInfo processInfo].systemUptime;
    
    if (_isCoastingForTouchEvent){
        if (_prevTouchTimerSecValid){
            double dt = nowSec - _prevTouchTimerSec;
            if (dt > 0.0){
                double alpha = 1.0 - exp(-dt / TOUCH_COAST_TAU_SEC);
                _speedRateByTouchEvents = (1.0 - alpha) * _speedRateByTouchEvents;
                if (fabs(_speedRateByTouchEvents) < TOUCH_COAST_END_EPSILON){
                    [self endTouchEventScratch];
                }else{
                    [_delegate turnTableSpeedRateChanged];
                    _prevTouchTimerSec = nowSec;
                    _prevTouchTimerSecValid = YES;
                }
            }
        }else{
            _prevTouchTimerSec = nowSec;
            _prevTouchTimerSecValid = YES;
        }
    }else if (_isPlatterTouchingByTouchEvents && _touchSpeedSmoothedValid){
        if (_prevTouchEventSecValid && (nowSec - _prevTouchEventSec) >= TOUCH_TARGET_IDLE_SEC){
            _touchSpeedTarget = 0.0;
            [self clearTouchTargetSamples];
        }
        if (_prevTouchTimerSecValid){
            double dt = nowSec - _prevTouchTimerSec;
            if (dt > 0.0){
                double alpha = 1.0 - exp(-dt / TOUCH_SPEED_TAU_SEC);
                _speedRateByTouchEvents = (1.0 - alpha) * _speedRateByTouchEvents + alpha * _touchSpeedTarget;
            }
        }
        _prevTouchTimerSec = nowSec;
        _prevTouchTimerSecValid = YES;
    }
    
    if (_isPlatterTouchingByMouseEvents || _isPlatterTouchingByTouchEvents || _isCoastingForTouchEvent){
        NSLog(@"[LogTimer] _speedRateByMouseEvents = %f, _speedRateByTouchEvents = %f target=%f coast=%d",
              _speedRateByMouseEvents, _speedRateByTouchEvents, _touchSpeedTarget, _isCoastingForTouchEvent);
    }
}

-(void)onUIUpdateTimer:(NSTimer *)t{
    if (_isPlatterTouchingByMouseEvents) return;

    _currentRad += [self baseRadS]*0.002;
    if (_currentRad > 2*M_PI){
        _currentRad -= 2*M_PI;
    }else if (_currentRad < 0){
        _currentRad += 2*M_PI;
    }

    [self setNeedsDisplay:YES];
}


- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    CGFloat r1 = self.bounds.size.height/2 - 10;
    CGFloat r2 = self.bounds.size.width/2 - 10;
    CGFloat r = 0;
    if (r1 > r2){
        r = r2;
    }else{
        r = r1;
    }
    
    NSRect circleRect = NSMakeRect(
                                   self.bounds.size.width/2 - r,
                                   self.bounds.size.height/2 - r,
                                   2*r,
                                   2*r);
    
    NSBezierPath *circlePath = [NSBezierPath bezierPathWithOvalInRect:circleRect];

    [[NSColor blackColor] set];
    [circlePath fill];

    CGFloat centerX = self.bounds.size.width/2;
    CGFloat centerY = self.bounds.size.height/2;

    CGFloat hubR = r * 2.5 / 10;
    NSRect hubRect = NSMakeRect(centerX - hubR, centerY - hubR, 2 * hubR, 2 * hubR);
    NSBezierPath *hubCircle = [NSBezierPath bezierPathWithOvalInRect:hubRect];
    [[NSColor whiteColor] set];
    [hubCircle fill];

    CGFloat tickInnerR = hubR;
    CGFloat tickOuterR = r * 3.0 / 10;
    NSBezierPath *ticks = [NSBezierPath bezierPath];
    [ticks setLineWidth:2.0];
    [[NSColor grayColor] set];
    UInt32 tickNum = 60;
    for (int i = 0; i < tickNum; i++) {
        double a = i * (2*M_PI / tickNum);
        [ticks moveToPoint:NSMakePoint(centerX + tickInnerR * cos(a), centerY + tickInnerR * sin(a))];
        [ticks lineToPoint:NSMakePoint(centerX + tickOuterR * cos(a), centerY + tickOuterR * sin(a))];
    }
    [ticks stroke];

    if (!_ring || [_ring sampleRate] <= 0){
        return;
    }

    // NSBezierPath *lineRecord = [NSBezierPath bezierPath];
    // [lineRecord moveToPoint:NSMakePoint(centerX,centerY)];
    // double thetaRecordRad = [_ring recordFrame]/[_ring sampleRate] * (-33.3/60 * 2 * M_PI);
    // [lineRecord lineToPoint:NSMakePoint(centerX + r*cos(thetaRecordRad)/3, centerY + r*sin(thetaRecordRad)/3)];
    // [[NSColor lightGrayColor] set];
    // [lineRecord setLineWidth:1.0];
    // [lineRecord stroke];
    
    CGFloat lineR = r * 5.0 / 10;
    NSBezierPath *linePlay = [NSBezierPath bezierPath];
    [linePlay moveToPoint:NSMakePoint(centerX,centerY)];
    double thetaPlayRad = [_ring playFrame]/[_ring sampleRate] * (-33.3/60 * 2 * M_PI);
    [linePlay lineToPoint:NSMakePoint(centerX + lineR*cos(thetaPlayRad), centerY + lineR*sin(thetaPlayRad))];
    [[NSColor orangeColor] set];
    [linePlay setLineWidth:3.0];
    [linePlay stroke];
    
}

-(NSPoint)eventLocation:(NSEvent *) theEvent{
    return [self convertPoint:theEvent.locationInWindow fromView:nil];
}


-(void)mouseDown:(NSEvent *)theEvent{
    CGFloat x = [self eventLocation:theEvent].x;
    CGFloat y = [self eventLocation:theEvent].y;
    
    x = x - self.bounds.size.width/2;
    y = y - self.bounds.size.height/2;
    
    CGFloat dist = sqrt(x*x + y*y);
    CGFloat r = self.bounds.size.height/2 - 10;
    
    if (dist <= r){
        _isCoastingForTouchEvent = NO;
        _isPlatterTouchingByMouseEvents = YES;
        double theta = x/sqrt(x*x + y*y);
        theta = acos(theta);
        if (y < 0) theta = 2*M_PI - theta;
        _startOffsetRad = theta - _currentRad;
        
        [self setNeedsDisplay:YES];
        [[NSCursor openHandCursor] set];
        _prevSec = theEvent.timestamp;
        _prevRad = _currentRad;
        _prevRadValid = YES;
        _speedRateByMouseEvents = 0.0;
        _historyCount = 0;
        for (int i = 0; i < 10; i++){
            _history[i] = 0.0;
        }
        [_delegate turnTableSpeedRateChanged];
    
    }else{
        _isPlatterTouchingByMouseEvents = NO;
    }
    
    
}

-(void)mouseUp:(NSEvent *)theEvent{
    _isPlatterTouchingByMouseEvents = NO;
    
    _speedRateByMouseEvents = 1.0;
    [_delegate turnTableSpeedRateChanged];
    
    [[NSCursor arrowCursor] set];
    [self setNeedsDisplay:YES];
}

-(void)onMouseDragTimer:(NSTimer *)t{
    if (!_isPlatterTouchingByMouseEvents) return;

    // Same time base as NSEvent.timestamp (seconds since system startup).
    double currentSec = [NSProcessInfo processInfo].systemUptime;

    //get mouse location
    NSPoint loc = [self.window mouseLocationOutsideOfEventStream];
    CGFloat x = [self convertPoint:loc fromView:nil].x;
    CGFloat y = [self convertPoint:loc fromView:nil].y;
    
    x = x - self.bounds.size.width/2;
    y = y - self.bounds.size.height/2;
    
    double theta = x/sqrt(x*x + y*y);
    theta = acos(theta);
    if (y < 0) theta = 2*M_PI-theta;
    _currentRad = theta - _startOffsetRad;
    if (_currentRad > 2*M_PI){
        _currentRad = _currentRad - 2 * M_PI;
    }
    if (_currentRad < 0 ){
        _currentRad = 2*M_PI + _currentRad;
    }
    
    double delta = _currentRad - _prevRad;
    if (fabs(rad2deg(delta)) > 340){
        if (_currentRad > _prevRad){
            delta = -1.0*_prevRad - (2*M_PI - _currentRad);
        }else{
            delta = (2*M_PI-_prevRad) + _currentRad;
        }
    }

    double dt = currentSec - _prevSec;
    if (dt > 0.0){
        double speed = delta / dt;
        double speedRate = speed / [self baseRadS];

        _history[0] = _history[1];
        _history[1] = _history[2];
        _history[2] = _history[3];
        _history[3] = _history[4];
        _history[4] = _history[5];
        _history[5] = _history[6];
        _history[6] = _history[7];
        _history[7] = _history[8];
        _history[8] = _history[9];
        _history[9] = speedRate;
        if (_historyCount < 10){
            _historyCount++;
        }
        double sum = 0.0;
        for (int i = 10 - _historyCount; i < 10; i++){
            sum += _history[i];
        }
        _speedRateByMouseEvents = sum / (double)_historyCount;

        [_delegate turnTableSpeedRateChanged];
    }
    
    _prevRad = _currentRad;
    _prevSec = currentSec;
    _prevX = x;
    _prevY = y;
    _prevRadValid = YES;
    
    [self setNeedsDisplay:YES];
    
}


-(double)speedRate{
    if (_isPlatterTouchingByMouseEvents){
        return _speedRateByMouseEvents;
    }else if (_isPlatterTouchingByTouchEvents || _isCoastingForTouchEvent){
        return _speedRateByTouchEvents;
    }else{
        return 1.0f;
    }
}

-(void)setSpeedRate:(float)speedRate{
    _speedRateByMouseEvents = speedRate;
}

-(void)setDelegate:(id<TurnTableDelegate>)delegate{
    _delegate = delegate;
}

-(void)setRingBuffer:(RingBuffer *)ring{
    _ring = ring;
}
-(Boolean)isUnderManualControl {
    return _isPlatterTouchingByMouseEvents || _isPlatterTouchingByTouchEvents || _isCoastingForTouchEvent;
}

- (void)logTouchesForEventType:(NSString *)eventType event:(NSEvent *)event {
    NSTimeInterval nowSec = event.timestamp;
    double dtMs = (sPrevTouchLogSec > 0) ? (nowSec - sPrevTouchLogSec) * 1000.0 : 0.0;
    sPrevTouchLogSec = nowSec;
    
    NSSet<NSTouch *> *touches = [event touchesMatchingPhase:NSTouchPhaseAny inView:self];
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithCapacity:touches.count];
    for (NSTouch *touch in touches) {
        NSInteger simpleId = SimpleTouchId(touch.identity);
        [parts addObject:[NSString stringWithFormat:@"id=%ld y=%f phase=%@ isResting=%d",
                          (long)simpleId,
                          touch.normalizedPosition.y,
                          NSTouchPhaseDescription(touch.phase),
                          touch.isResting]];
        if (touch.phase == NSTouchPhaseEnded || touch.phase == NSTouchPhaseCancelled) {
//            ForgetSimpleTouchId(touch.identity);
        }
    }
    
//    NSLog(@"%@ +%.1fms fingers=%lu touches=[%@]",
//          eventType,
//          dtMs,
//          (unsigned long)touches.count,
//          [parts componentsJoinedByString:@"; "]);
}

- (void)handle2FingerTouchForEventType:(NSString *)eventType event:(NSEvent *)event {
    NSSet<NSTouch *> *touches = [event touchesMatchingPhase:NSTouchPhaseAny inView:self];
    if (touches.count != 2){
        return;
    }
    
    double sumY = 0.0;
    for (NSTouch *touch in touches) {
        sumY += touch.normalizedPosition.y;
    }
    double centroidY = sumY / 2.0;
    
    if ([eventType isEqualToString:@"touchesEnded"] || [eventType isEqualToString:@"touchesCancelled"]){
        if (!_touchSpeedSmoothedValid || fabs(_speedRateByTouchEvents) < TOUCH_COAST_SKIP_EPSILON){
            [self endTouchEventScratch];
        }else{
            [self beginCoastForTouchEvent];
        }
        return;
    }
    
    if ([eventType isEqualToString:@"touchesBegan"] || !_prevTouchEventSecValid){
        _isCoastingForTouchEvent = NO;
        _prevTouchCentroidY = centroidY;
        _prevTouchEventSec = event.timestamp;
        _prevTouchEventSecValid = YES;
        _touchSpeedSmoothedValid = NO;
        _prevTouchTimerSecValid = NO;
        _touchSpeedTarget = 0.0;
        _speedRateByTouchEvents = 0.0;
        [self clearTouchTargetSamples];
        [_delegate turnTableSpeedRateChanged];
        return;
    }
    
    double dy = centroidY - _prevTouchCentroidY;
    if (fabs(dy) < TOUCH_CENTROID_Y_EPSILON){
        return;
    }
    
    double dt = event.timestamp - _prevTouchEventSec;
    if (dt > 0.0){
        double vRaw = (dy / dt) / TOUCH_Y_PER_SEC_FOR_1X;
        _touchSpeedTarget = [self pushTouchTargetSample:vRaw at:event.timestamp];
        
        if (!_touchSpeedSmoothedValid){
            _speedRateByTouchEvents = _touchSpeedTarget;
            _touchSpeedSmoothedValid = YES;
        }else{
            double alpha = 1.0 - exp(-dt / TOUCH_SPEED_TAU_SEC);
            _speedRateByTouchEvents = (1.0 - alpha) * _speedRateByTouchEvents + alpha * _touchSpeedTarget;
        }
        
        [_delegate turnTableSpeedRateChanged];
    }
    
    _prevTouchCentroidY = centroidY;
    _prevTouchEventSec = event.timestamp;
    _prevTouchEventSecValid = YES;
}

- (void)touchesBeganWithEvent:(NSEvent *)event {
    NSSet<NSTouch *> *touches = [event touchesMatchingPhase:NSTouchPhaseAny inView:self];
    if (touches.count == 2){
        [self logTouchesForEventType:@"touchesBegan" event:event];
        _isPlatterTouchingByTouchEvents = YES;
        [self handle2FingerTouchForEventType:@"touchesBegan" event:event];
    }
}

- (void)touchesMovedWithEvent:(NSEvent *)event {
    NSSet<NSTouch *> *touches = [event touchesMatchingPhase:NSTouchPhaseAny inView:self];
    if (touches.count == 2){
        [self logTouchesForEventType:@"touchesMoved" event:event];
        [self handle2FingerTouchForEventType:@"touchesMoved" event:event];
    }
}

- (void)touchesEndedWithEvent:(NSEvent *)event {
    NSSet<NSTouch *> *touches = [event touchesMatchingPhase:NSTouchPhaseAny inView:self];
    if (touches.count == 2){
        [self logTouchesForEventType:@"touchesEnded" event:event];
        [self handle2FingerTouchForEventType:@"touchesEnded" event:event];
    }
}

- (void)touchesCancelledWithEvent:(NSEvent *)event {
    NSSet<NSTouch *> *touches = [event touchesMatchingPhase:NSTouchPhaseAny inView:self];
    if (touches.count == 2){
        [self logTouchesForEventType:@"touchesCancelled" event:event];
        [self handle2FingerTouchForEventType:@"touchesCancelled" event:event];
    }
}

@end
