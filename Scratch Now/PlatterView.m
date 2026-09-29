//
//  PlatterView.m
//  Scratch Now
//
//  Created by kyab on 2017/05/08.
//  Copyright © 2017年 kyab. All rights reserved.
//

#import "PlatterView.h"

#define REDRAW_TIMER_SEC 0.002
#define MOUSE_DRAG_TIMER_SEC 0.01
#define TOUCH_TIMER_SEC 0.01

#define TOUCH_Y_PER_SEC_FOR_1X 1.0
#define TOUCH_CENTROID_Y_EPSILON 0.000001
#define TOUCH_SPEED_TAU_SEC 0.01
#define TOUCH_TARGET_IDLE_SEC 0.1
#define TOUCH_TARGET_WINDOW_SEC 0.05

typedef NS_ENUM(NSInteger, PlatterTouchPhase) {
    PlatterTouchPhaseBegan,
    PlatterTouchPhaseMoved,
};

@implementation PlatterView


- (void)awakeFromNib{
    _currentRad = 28 * (M_PI / 180);
    _speedRateByMouseEvents = 1.0f;
    _speedRateByTouchEvents = 1.0f;

    [self setAllowedTouchTypes:NSTouchTypeMaskDirect | NSTouchTypeMaskIndirect];

    _mouseDragTimer = [NSTimer scheduledTimerWithTimeInterval:MOUSE_DRAG_TIMER_SEC target:self selector:@selector(onMouseDragTimer:) userInfo:nil repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:_mouseDragTimer forMode:NSRunLoopCommonModes];

    _touchTimer = [NSTimer scheduledTimerWithTimeInterval:TOUCH_TIMER_SEC target:self selector:@selector(onTouchTimer:) userInfo:nil repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:_touchTimer forMode:NSRunLoopCommonModes];
    
    _redrawTimer = [NSTimer scheduledTimerWithTimeInterval:REDRAW_TIMER_SEC target:self selector:@selector(onRedrawTimer:) userInfo:nil repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:_redrawTimer forMode:NSRunLoopCommonModes];
}

-(void)setDelegate:(id<PlatterViewDelegate>)delegate{
    _delegate = delegate;
}

-(void)setTurnTable:(TurnTable *)turnTable{
    _turnTable = turnTable;
}

-(double) baseRadS{
    return -33.3/60 * M_PI*2;
}

static double rad2deg(double rad){
    return rad / M_PI * 180;
}

#pragma mark - Drawing

-(void)onRedrawTimer:(NSTimer *)t{
    if (_isPlatterTouchingByMouseEvents) return;

    _currentRad += [self baseRadS]*REDRAW_TIMER_SEC;
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

    RingBuffer *ring = [_turnTable ring];
    if (!ring || [ring sampleRate] <= 0){
        return;
    }

    CGFloat lineR = r * 5.0 / 10;
    NSBezierPath *linePlay = [NSBezierPath bezierPath];
    [linePlay moveToPoint:NSMakePoint(centerX,centerY)];
    double thetaPlayRad = [ring playFrame]/[ring sampleRate] * (-33.3/60 * 2 * M_PI);
    [linePlay lineToPoint:NSMakePoint(centerX + lineR*cos(thetaPlayRad), centerY + lineR*sin(thetaPlayRad))];
    if ([ring readWriteOffset] > 128){
        //skyblue for unsync state.
        [[NSColor colorWithCalibratedRed:0.28 green:0.65 blue:0.92 alpha:1.0] set];
    }else{
        [[NSColor orangeColor] set];
    }

    [linePlay setLineWidth:3.0];
    [linePlay stroke];
}

#pragma mark - Mouse

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

    if (dist <= r && _activeDevice == PlatterInputDeviceNone){
        _activeDevice = PlatterInputDeviceMouse;
        _isPlatterTouchingByMouseEvents = YES;
        double theta = x/sqrt(x*x + y*y);
        theta = acos(theta);
        if (y < 0) theta = 2*M_PI - theta;
        _startOffsetRad = theta - _currentRad;

        [self setNeedsDisplay:YES];
        [[NSCursor openHandCursor] set];
        _prevSec = theEvent.timestamp;
        _prevRad = _currentRad;
        _speedRateByMouseEvents = 0.0;
        _historyCount = 0;
        for (int i = 0; i < MOUSE_SPEED_HISTORY_NUM; i++){
            _history[i] = 0.0;
        }
        [_delegate platterViewScratchBegan:self];
    }
}

-(void)mouseUp:(NSEvent *)theEvent{
    if (_activeDevice != PlatterInputDeviceMouse) return;

    double releaseSpeed = _speedRateByMouseEvents;
    _isPlatterTouchingByMouseEvents = NO;
    _speedRateByMouseEvents = 1.0;
    _activeDevice = PlatterInputDeviceNone;
    [_delegate platterView:self scratchEndedWithReleaseSpeed:releaseSpeed];

    [[NSCursor arrowCursor] set];
    [self setNeedsDisplay:YES];
}

-(void)onMouseDragTimer:(NSTimer *)t{
    if (!_isPlatterTouchingByMouseEvents) return;

    // Same time base as NSEvent.timestamp (seconds since system startup).
    double currentSec = [NSProcessInfo processInfo].systemUptime;

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

        for (int i = 0; i < MOUSE_SPEED_HISTORY_NUM - 1; i++){
            _history[i] = _history[i + 1];
        }
        _history[MOUSE_SPEED_HISTORY_NUM - 1] = speedRate;
        if (_historyCount < MOUSE_SPEED_HISTORY_NUM){
            _historyCount++;
        }
        double sum = 0.0;
        for (int i = MOUSE_SPEED_HISTORY_NUM - _historyCount; i < MOUSE_SPEED_HISTORY_NUM; i++){
            sum += _history[i];
        }
        _speedRateByMouseEvents = sum / (double)_historyCount;

        [_delegate platterView:self scratchSpeedChanged:_speedRateByMouseEvents];
    }

    _prevRad = _currentRad;
    _prevSec = currentSec;

    [self setNeedsDisplay:YES];
}

#pragma mark - Two-finger touch

-(void)clearTouchTargetSamples{
    _touchTargetSampleCount = 0;
}

// Time-weighted mean of the raw centroid velocities within TOUCH_TARGET_WINDOW_SEC.
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

-(void)resetTouchState{
    _isPlatterTouchingByTouchEvents = NO;
    _speedRateByTouchEvents = 1.0;
    _touchSpeedTarget = 1.0;
    _prevTouchEventSecValid = NO;
    _touchSpeedSmoothedValid = NO;
    _prevTouchTimerSecValid = NO;
    [self clearTouchTargetSamples];
}

-(void)onTouchTimer:(NSTimer *)t{
    if (!_isPlatterTouchingByTouchEvents || !_touchSpeedSmoothedValid) return;

    NSTimeInterval nowSec = [NSProcessInfo processInfo].systemUptime;
    if (_prevTouchEventSecValid && (nowSec - _prevTouchEventSec) >= TOUCH_TARGET_IDLE_SEC){
        _touchSpeedTarget = 0.0;
        [self clearTouchTargetSamples];
    }
    if (_prevTouchTimerSecValid){
        double dt = nowSec - _prevTouchTimerSec;
        if (dt > 0.0){
            double alpha = 1.0 - exp(-dt / TOUCH_SPEED_TAU_SEC);
            _speedRateByTouchEvents = (1.0 - alpha) * _speedRateByTouchEvents + alpha * _touchSpeedTarget;
            [_delegate platterView:self scratchSpeedChanged:_speedRateByTouchEvents];
        }
    }
    _prevTouchTimerSec = nowSec;
    _prevTouchTimerSecValid = YES;
}

-(void)endTouchScratch{
    double releaseSpeed = _speedRateByTouchEvents;
    [self resetTouchState];
    _activeDevice = PlatterInputDeviceNone;
    [_delegate platterView:self scratchEndedWithReleaseSpeed:releaseSpeed];
}

- (void)handle2FingerTouchWithEvent:(NSEvent *)event phase:(PlatterTouchPhase)phase {
    NSSet<NSTouch *> *touches = [event touchesMatchingPhase:NSTouchPhaseAny inView:self];
    if (touches.count != 2){
        return;
    }

    double sumY = 0.0;
    for (NSTouch *touch in touches) {
        sumY += touch.normalizedPosition.y;
    }
    double centroidY = sumY / 2.0;

    if (phase == PlatterTouchPhaseBegan || !_prevTouchEventSecValid){
        _prevTouchCentroidY = centroidY;
        _prevTouchEventSec = event.timestamp;
        _prevTouchEventSecValid = YES;
        _touchSpeedSmoothedValid = NO;
        _prevTouchTimerSecValid = NO;
        _touchSpeedTarget = 0.0;
        _speedRateByTouchEvents = 0.0;
        [self clearTouchTargetSamples];
        [_delegate platterViewScratchBegan:self];
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

        [_delegate platterView:self scratchSpeedChanged:_speedRateByTouchEvents];
    }

    _prevTouchCentroidY = centroidY;
    _prevTouchEventSec = event.timestamp;
    _prevTouchEventSecValid = YES;
}

- (void)touchesBeganWithEvent:(NSEvent *)event {
    if (_activeDevice != PlatterInputDeviceNone) return;

    NSSet<NSTouch *> *touches = [event touchesMatchingPhase:NSTouchPhaseAny inView:self];
    if (touches.count == 2){
        _activeDevice = PlatterInputDeviceTouch;
        _isPlatterTouchingByTouchEvents = YES;
        [self handle2FingerTouchWithEvent:event phase:PlatterTouchPhaseBegan];
    }
}

- (void)touchesMovedWithEvent:(NSEvent *)event {
    if (_activeDevice != PlatterInputDeviceTouch) return;
    [self handle2FingerTouchWithEvent:event phase:PlatterTouchPhaseMoved];
}

- (void)touchesEndedWithEvent:(NSEvent *)event {
    if (_activeDevice != PlatterInputDeviceTouch) return;
    [self endTouchScratch];
}

- (void)touchesCancelledWithEvent:(NSEvent *)event {
    if (_activeDevice != PlatterInputDeviceTouch) return;
    [self endTouchScratch];
}

@end
