 //
//  TurnTableView.m
//  Fluent Scratch
//
//  Created by kyab on 2017/05/08.
//  Copyright © 2017年 kyab. All rights reserved.
//

#import "TurnTableView.h"

// Two-finger scroll scratch tuning.
// Finger speed (in scroll points/sec) that maps to 1.0x playback (33.3 RPM).
#define SCROLL_POINTS_PER_SEC_FOR_1X 600.0
// Per-event exponential smoothing of the instantaneous velocity.
#define SCROLL_SPEED_EMA_ALPHA 0.4
// No scroll delta for this long while touching = fingers resting -> hold the record.
#define SCROLL_HOLD_SEC 0.05
// After fingers lift, wait this long for OS momentum events before releasing.
#define SCROLL_END_GRACE_SEC 0.1
#define SCROLL_STOP_EPSILON 0.001

@implementation TurnTableView


- (void)awakeFromNib{
    _currentRad = 28 * (M_PI / 180);
    _speedRate = 1.0f;
    
    _timer2 = [NSTimer scheduledTimerWithTimeInterval:0.01 target:self selector:@selector(onTimerScratch:) userInfo:nil repeats:YES];

    [[NSRunLoop currentRunLoop] addTimer:_timer2 forMode:NSRunLoopCommonModes];
    
}

- (void)start{
    if (!_timer){
        _timer = [NSTimer scheduledTimerWithTimeInterval:0.002 target:self selector:@selector(onTimer:) userInfo:nil repeats:YES];
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

-(void)onTimer:(NSTimer *)t{
    if (_isPlatterTouching) return;

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
    

    [[NSColor grayColor] set];
    [circlePath fill];
    
    
    CGFloat centerX = self.bounds.size.width/2;
    CGFloat centerY = self.bounds.size.height/2;


    
    if (!_ring || [_ring sampleRate] <= 0){
        return;
    }
    
    NSBezierPath *lineRecord = [NSBezierPath bezierPath];
    [lineRecord moveToPoint:NSMakePoint(centerX,centerY)];
    double thetaRecordRad = [_ring recordFrame]/[_ring sampleRate] * (-33.3/60 * 2 * M_PI);
    [lineRecord lineToPoint:NSMakePoint(centerX + r*cos(thetaRecordRad)/3, centerY + r*sin(thetaRecordRad)/3)];
    [[NSColor lightGrayColor] set];
    [lineRecord setLineWidth:1.0];
    [lineRecord stroke];
    
    NSBezierPath *linePlay = [NSBezierPath bezierPath];
    [linePlay moveToPoint:NSMakePoint(centerX,centerY)];
    double thetaPlayRad = [_ring playFrame]/[_ring sampleRate] * (-33.3/60 * 2 * M_PI);
    [linePlay lineToPoint:NSMakePoint(centerX + r*cos(thetaPlayRad), centerY + r*sin(thetaPlayRad))];
    if (_isPlatterTouching){
        [[NSColor orangeColor] set ];
    }else{
        [[NSColor orangeColor] set];
    }
    [linePlay setLineWidth:5.0];
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
        _isPlatterTouching = YES;
        double theta = x/sqrt(x*x + y*y);
        theta = acos(theta);
        if (y < 0) theta = 2*M_PI - theta;
        _startOffsetRad = theta - _currentRad;
        
        [self setNeedsDisplay:YES];
        [[NSCursor openHandCursor] set];
        _prevSec = theEvent.timestamp;
        _prevRad = _currentRad;
        _prevRadValid = YES;
        _speedRate = 0.0;
        _historyCount = 0;
        for (int i = 0; i < 10; i++){
            _history[i] = 0.0;
        }
        [_delegate turnTableSpeedRateChanged];
    
    }else{
        _isPlatterTouching = NO;
    }
    
    
}

-(void)mouseDragged:(NSEvent *)theEvent{
//    if (_pressing == NO) return;
//    if (_pressing == YES) return;
//
//    CGFloat x1 = [self eventLocation:theEvent].x;
//    CGFloat y1 = [self eventLocation:theEvent].y;
//
//    x1 = x1 - self.bounds.size.width/2;
//    y1 = y1 - self.bounds.size.height/2;
//    double theta = x1/sqrt(x1*x1 + y1*y1);
//    theta = acos(theta);
//    if (y1 <0 ) theta = 2*M_PI - theta;
//    _currentRad  = theta - _startOffsetRad;
//    if (_currentRad > 2*M_PI){
//        _currentRad = _currentRad -  2*M_PI;
//    }
//    if (_currentRad < 0){
//        _currentRad = 2*M_PI + _currentRad;
//    }
//
//    double delta  = _currentRad - _prevRad;
//    if (fabs(rad2deg(delta)) > 340){
//        if (_currentRad > _prevRad){
//            delta = -1.0*_prevRad - (2*M_PI - _currentRad);
//        }else{
//            delta = (2*M_PI-_prevRad) + _currentRad;
//        }
//    }
//
//    double speed = delta / ([theEvent timestamp] - _prevSec);
//    _speedRate = speed / [self baseRadS];
//
//    [_delegate turnTableSpeedRateChanged];
//
//    _prevRad = _currentRad;
//    _prevSec = [theEvent timestamp];
//    _prevX = x1;
//    _prevY = y1;
//
//    [self setNeedsDisplay:YES];
//
}

-(void)mouseUp:(NSEvent *)theEvent{
    _isPlatterTouching = NO;
    
    _speedRate = 1.0;
    [_delegate turnTableSpeedRateChanged];
    
    [[NSCursor arrowCursor] set];
    [self setNeedsDisplay:YES];
}

-(void)onTimerScratch:(NSTimer *)t{
    if (_isScrollScratching) return;
    if (!_isPlatterTouching) return;

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
        _speedRate = sum / (double)_historyCount;

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
    return _speedRate;
}

-(void)setSpeedRate:(float)speedRate{
    _speedRate = speedRate;
}

-(void)setDelegate:(id<TurnTableDelegate>)delegate{
    _delegate = delegate;
}

-(void)setRingBuffer:(RingBuffer *)ring{
    _ring = ring;
}
-(Boolean)isPlatterTouching {
    return _isPlatterTouching;
}

-(void)beginScrollScratch{
    _isScrollScratching = YES;
    _scrollEndPending = NO;
    _prevScrollEventSecValid = NO;
    _isPlatterTouching = YES;
    
    _speedRate = 0.0;
    _lastScrollMoveSec = [NSProcessInfo processInfo].systemUptime;
    [_delegate turnTableSpeedRateChanged];
    
    if (!_scrollTimer){
        _scrollTimer = [NSTimer scheduledTimerWithTimeInterval:0.01 target:self selector:@selector(onTimerScrollScratch:) userInfo:nil repeats:YES];
        [[NSRunLoop currentRunLoop] addTimer:_scrollTimer forMode:NSRunLoopCommonModes];
    }
    [self setNeedsDisplay:YES];
}

-(void)endScrollScratch{
    [_scrollTimer invalidate];
    _scrollTimer = nil;
    _isScrollScratching = NO;
    _scrollEndPending = NO;
    _isPlatterTouching = NO;
    
    _speedRate = 1.0;
    [_delegate turnTableSpeedRateChanged];
    [self setNeedsDisplay:YES];
}

-(void)onTimerScrollScratch:(NSTimer *)t{
    if (!_isScrollScratching) return;
    
    NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
    
    if (_scrollEndPending && (now - _scrollEndPendingSec) > SCROLL_END_GRACE_SEC){
        [self endScrollScratch];
        return;
    }
    
    if ((now - _lastScrollMoveSec) > SCROLL_HOLD_SEC){
        _speedRate *= 0.5;
        if (fabs(_speedRate) < SCROLL_STOP_EPSILON){
            _speedRate = 0.0;
        }
    }
    
    _currentRad += [self baseRadS] * _speedRate * 0.01;
    if (_currentRad > 2*M_PI){
        _currentRad -= 2*M_PI;
    }else if (_currentRad < 0){
        _currentRad += 2*M_PI;
    }
    
    [_delegate turnTableSpeedRateChanged];
    [self setNeedsDisplay:YES];
}

-(void)scrollWheel:(NSEvent *)event{
    NSEventPhase phase = event.phase;
    NSEventPhase momentumPhase = event.momentumPhase;
    
    if (phase == NSEventPhaseBegan){
        if (!_isPlatterTouching && !_isScrollScratching){
            [self beginScrollScratch];
        }
        if (_isScrollScratching){
            _scrollEndPending = NO;
            _prevScrollEventSecValid = NO;
        }
    }
    
    if (!_isScrollScratching) return;
    
    if (phase == NSEventPhaseEnded || phase == NSEventPhaseCancelled){
        _scrollEndPending = YES;
        _scrollEndPendingSec = event.timestamp;
        _prevScrollEventSecValid = NO;
        return;
    }
    
    if (momentumPhase == NSEventPhaseBegan){
        _scrollEndPending = NO;
        _prevScrollEventSecValid = NO;
    }
    if (momentumPhase == NSEventPhaseEnded || momentumPhase == NSEventPhaseCancelled){
        [self endScrollScratch];
        return;
    }
    
    if (phase == NSEventPhaseBegan || phase == NSEventPhaseChanged ||
        momentumPhase == NSEventPhaseBegan || momentumPhase == NSEventPhaseChanged){
        // Normalize to physical finger motion (fingers up = forward),
        // independent of the system "natural scrolling" preference.
        double dy = event.scrollingDeltaY;
        if (event.isDirectionInvertedFromDevice){
            dy = -dy;
        }
        
        NSTimeInterval ts = event.timestamp;
        if (_prevScrollEventSecValid){
            double dt = ts - _prevScrollEventSec;
            if (dt > 0.0){
                double instRate = (dy / dt) / SCROLL_POINTS_PER_SEC_FOR_1X;
                _speedRate += SCROLL_SPEED_EMA_ALPHA * (instRate - _speedRate);
                _lastScrollMoveSec = ts;
            }
        }
        _prevScrollEventSec = ts;
        _prevScrollEventSecValid = YES;
    }
}

@end
