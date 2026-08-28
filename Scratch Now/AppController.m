//
//  AppController.m
//  Scratch Now
//
//  Created by kyab on 2021/06/19.
//

#import "AppController.h"
#include <math.h>
#include <string.h>
#include <stdio.h>

#if SCRATCH_NOW_TAP_SMOKE_CI
// UI scratch E2E CI: the external harness needs the turntable position in
// CGEvent global coordinates (top-left origin) to post synthetic mouse events,
// and a low-rate scratch state stream to verify direction/state transitions.
static NSString *UIScratchCIPath(NSString *fileName){
    NSString *dir = @"/tmp/scratch-now-tap-smoke-ci";
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    return [dir stringByAppendingPathComponent:fileName];
}

static void UIScratchCIAppendLine(NSString *fileName, NSString *line){
    const char *utf8 = [line UTF8String];
    FILE *f = fopen([UIScratchCIPath(fileName) fileSystemRepresentation], "a");
    if (f){
        fwrite(utf8, 1, strlen(utf8), f);
        fclose(f);
    }
}

static NSTimer *sUIScratchCITimer = nil;
#endif

#define FADE_SAMPLE_NUM 500
#define SPEED_SMOOTH_ALPHA (1.0 / 128.0)
#define GAIN_SMOOTH_ALPHA (1.0 / 256.0)
#define DC_BLOCKER_R (0.995f)
#define GAIN_SLOPE (4.0)
#define STOPPED_SPEED_EPSILON (1.0e-4)

static inline float cubicInterpolate(float y0, float y1, float y2, float y3, double mu) {
    double mu2 = mu * mu;
    double a0 = (double)y3 - (double)y2 - (double)y0 + (double)y1;
    double a1 = (double)y0 - (double)y1 - a0;
    double a2 = (double)y2 - (double)y0;
    double a3 = (double)y1;
    return (float)((mu * mu2 * a0) + (mu2 * a1) + (mu * a2) + a3);
}

@implementation AppController

-(void)resetScratchState{
    _isScratchStarting = NO;
    _isScratchEnding = NO;
    _isFadingOut = NO;
    _isFadingIn = NO;
    _isScratching = NO;
    _fadeOutCounter = 0;
    _fadeInCounter = 0;
    _smoothedSpeed = 1.0;
    _subSamplePos = 0.0;
    _wetGain = 1.0;
    _dcInL = 0.0f;
    _dcOutL = 0.0f;
    _dcInR = 0.0f;
    _dcOutR = 0.0f;
}

-(void)awakeFromNib{
    _speedRate = 1.0;
    _tableStopSpeed = 1.0;
    _dryVolume = 0.0;
    _wetVolume = 1.0;
    [self resetScratchState];

    //Initialize the engine first: the device-specific tap decides the pipeline sample rate,
    //which the ring buffer allocation depends on.
    _ae = [[AudioEngine alloc] init];
    [_ae setRenderDelegate:(id<AudioEngineDelegate>)self];
    if([_ae initialize]){
        NSLog(@"AudioEngine all OK");
    }

    _ring = [[RingBuffer alloc] initWithSampleRate:[_ae sampleRate]];
    [_turnTableView setRingBuffer:_ring];
    [_turnTableView setDelegate:(id<TurnTableDelegate>)self];
    [_turnTableView start];

    [_ae startOutput];
    [_ae startInput];

#if SCRATCH_NOW_TAP_SMOKE_CI
    [self startUIScratchCIReporting];
#endif
}

#if SCRATCH_NOW_TAP_SMOKE_CI
-(void)startUIScratchCIReporting{
    // Log the turntable geometry after the window has settled on screen.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self logUIScratchCIGeometry];
    });

    sUIScratchCITimer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                         target:self
                                                       selector:@selector(onUIScratchCITimer:)
                                                       userInfo:nil
                                                        repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:sUIScratchCITimer forMode:NSRunLoopCommonModes];
}

-(void)logUIScratchCIGeometry{
    TurnTableView *view = _turnTableView;
    NSWindow *window = view.window;
    if (!view || !window){
        UIScratchCIAppendLine(@"ui.jsonl", @"{\"error\":\"turntable window unavailable\"}\n");
        return;
    }

    NSRect rectInWindow = [view convertRect:view.bounds toView:nil];
    NSRect rectOnScreen = [window convertRectToScreen:rectInWindow];
    // CGEvent global coordinates use a top-left origin on the primary screen.
    CGFloat primaryHeight = NSScreen.screens.firstObject.frame.size.height;
    double centerX = NSMidX(rectOnScreen);
    double centerY = (double)primaryHeight - (double)NSMidY(rectOnScreen);
    // Matches the platter hit test in TurnTableView mouseDown (height/2 - 10).
    double radius = view.bounds.size.height / 2.0 - 10.0;

    // Stop button center so the driver can exercise the table-stop cases.
    double btnStopCenterX = 0.0;
    double btnStopCenterY = 0.0;
    NSButton *btnStop = _btnStop;
    if (btnStop){
        NSRect btnRectOnScreen = [window convertRectToScreen:
                                  [btnStop convertRect:btnStop.bounds toView:nil]];
        btnStopCenterX = NSMidX(btnRectOnScreen);
        btnStopCenterY = (double)primaryHeight - (double)NSMidY(btnRectOnScreen);
    }

    NSString *line = [NSString stringWithFormat:
                      @"{\"ts\":%.3f,\"centerX\":%.2f,\"centerY\":%.2f,\"radius\":%.2f,"
                      @"\"screenHeight\":%.2f,\"viewWidth\":%.2f,\"viewHeight\":%.2f,"
                      @"\"btnStopCenterX\":%.2f,\"btnStopCenterY\":%.2f}\n",
                      [[NSDate date] timeIntervalSince1970],
                      centerX, centerY, radius,
                      (double)primaryHeight,
                      (double)view.bounds.size.width,
                      (double)view.bounds.size.height,
                      btnStopCenterX, btnStopCenterY];
    UIScratchCIAppendLine(@"ui.jsonl", line);
}

-(void)onUIScratchCITimer:(NSTimer *)t{
    NSString *line = [NSString stringWithFormat:
                      @"{\"ts\":%.3f,\"speedRate\":%.4f,\"smoothedSpeed\":%.4f,"
                      @"\"pressing\":%d,\"scratching\":%d,"
                      @"\"tableStopped\":%d,\"tableStopSpeed\":%.4f,\"stopTimerActive\":%d,"
                      @"\"playFrame\":%u,\"recordFrame\":%u}\n",
                      [[NSDate date] timeIntervalSince1970],
                      _speedRate, _smoothedSpeed,
                      [_turnTableView isScratching] ? 1 : 0,
                      _isScratching ? 1 : 0,
                      _tableStopped ? 1 : 0,
                      _tableStopSpeed,
                      (_tableStopTimer != nil) ? 1 : 0,
                      [_ring playFrame], [_ring recordFrame]];
    UIScratchCIAppendLine(@"scratch.jsonl", line);
}
#endif

- (OSStatus) inCallback:(AudioUnitRenderActionFlags *)ioActionFlags inTimeStamp:(const AudioTimeStamp *) inTimeStamp inBusNumber:(UInt32) inBusNumber inNumberFrames:(UInt32)inNumberFrames ioData:(AudioBufferList *)ioData{
    static BOOL printNumFrames = NO;
    if (!printNumFrames){
        NSLog(@"inCallback NumFrames = %d", inNumberFrames);
        printNumFrames = YES;
    }

    AudioBufferList *bufferList = (AudioBufferList *)malloc(sizeof(AudioBufferList) +  sizeof(AudioBuffer)); // for 2 buffers for left and right

    float *leftPrt = [_ring writePtrLeft];
    float *rightPtr = [_ring writePtrRight];

    bufferList->mNumberBuffers = 2;
    bufferList->mBuffers[0].mDataByteSize = 32*inNumberFrames;
    bufferList->mBuffers[0].mNumberChannels = 1;
    bufferList->mBuffers[0].mData = leftPrt;
    bufferList->mBuffers[1].mDataByteSize = 32*inNumberFrames;
    bufferList->mBuffers[1].mNumberChannels = 1;
    bufferList->mBuffers[1].mData = rightPtr;

    OSStatus ret = [_ae readFromInput:ioActionFlags inTimeStamp:inTimeStamp inBusNumber:inBusNumber inNumberFrames:inNumberFrames ioData:bufferList];
    free(bufferList);

    if ([_ae isRecording]){
        [_ring advanceWritePtrSample:inNumberFrames];
    }

    return ret;
}

-(void)resampleFromLeft:(float *)baseL
                  right:(float *)baseR
              toDstLeft:(float *)dstL
               dstRight:(float *)dstR
                samples:(UInt32)numSamples
             startSpeed:(double)startSpeed
               endSpeed:(double)endSpeed
                 subPos:(double *)subPos
               consumed:(SInt32 *)consumed{
    double pos = *subPos;
    double speed = startSpeed;
    double dSpeed = (endSpeed - startSpeed) / (double)numSamples;
    SInt32 integerBase = 0;

    for (UInt32 i = 0; i < numSamples; i++){
        while (pos >= 1.0){ pos -= 1.0; integerBase += 1; }
        while (pos < 0.0){ pos += 1.0; integerBase -= 1; }

        float l0 = baseL[integerBase - 1];
        float l1 = baseL[integerBase];
        float l2 = baseL[integerBase + 1];
        float l3 = baseL[integerBase + 2];
        float r0 = baseR[integerBase - 1];
        float r1 = baseR[integerBase];
        float r2 = baseR[integerBase + 1];
        float r3 = baseR[integerBase + 2];

        dstL[i] = cubicInterpolate(l0, l1, l2, l3, pos);
        dstR[i] = cubicInterpolate(r0, r1, r2, r3, pos);
        pos += speed;
        speed += dSpeed;
    }

    while (pos >= 1.0){ pos -= 1.0; integerBase += 1; }
    while (pos < 0.0){ pos += 1.0; integerBase -= 1; }

    *subPos = pos;
    *consumed = integerBase;
}

// Variable-rate wet (Hermite) + 1x dry mix. Used for scratch, Stop ramp, and stopped platter.
-(void)processVariableRateBlock:(float *)leftBuf right:(float *)rightBuf samples:(UInt32)numSamples applyExtraFade:(BOOL)applyExtraFade{
    if (numSamples == 0) return;

    double targetSpeed = _speedRate;
    double speedStart = _smoothedSpeed;
    double speedEnd = speedStart;
    for (UInt32 i = 0; i < numSamples; i++){
        speedEnd += (targetSpeed - speedEnd) * SPEED_SMOOTH_ALPHA;
    }

    double absMean = 0.5 * (fabs(speedStart) + fabs(speedEnd));
    double targetGain = absMean * GAIN_SLOPE;
    if (targetGain > 1.0) targetGain = 1.0;
    if (absMean < STOPPED_SPEED_EPSILON) targetGain = 0.0;

    double gainStart = _wetGain;
    double gainEnd = gainStart;
    for (UInt32 i = 0; i < numSamples; i++){
        gainEnd += (targetGain - gainEnd) * GAIN_SMOOTH_ALPHA;
    }

    // Wet: variable-rate resample from the play (read) pointer.
    float *baseL = [_ring readPtrLeft];
    float *baseR = [_ring readPtrRight];
    SInt32 consumed = 0;
    if (baseL != NULL && baseR != NULL){
        [self resampleFromLeft:baseL right:baseR toDstLeft:_tempLeftPtr dstRight:_tempRightPtr samples:numSamples startSpeed:speedStart endSpeed:speedEnd subPos:&_subSamplePos consumed:&consumed];
    }else{
        memset(_tempLeftPtr, 0, sizeof(float) * numSamples);
        memset(_tempRightPtr, 0, sizeof(float) * numSamples);
    }

    // Dry: independent 1x realtime pointer (same model as pre-Hermite path).
    // leftBuf/rightBuf are AU output buffers and must not be used as dry source.
    float *drySrcL = [_ring dryPtrLeft];
    float *drySrcR = [_ring dryPtrRight];

    double gain = gainStart;
    double dGain = (gainEnd - gainStart) / (double)numSamples;
    float dcInL = _dcInL;
    float dcOutL = _dcOutL;
    float dcInR = _dcInR;
    float dcOutR = _dcOutR;

    double extraFade = applyExtraFade ? (_fadeOutCounter / (double)FADE_SAMPLE_NUM) : 1.0;
    double extraFadeEnd;
    if (applyExtraFade){
        SInt32 counterEnd = (SInt32)_fadeOutCounter - (SInt32)numSamples;
        if (counterEnd < 0) counterEnd = 0;
        extraFadeEnd = counterEnd / (double)FADE_SAMPLE_NUM;
    }else{
        extraFadeEnd = 1.0;
    }
    double dExtraFade = (extraFadeEnd - extraFade) / (double)numSamples;

    for (UInt32 i = 0; i < numSamples; i++){
        float inL = _tempLeftPtr[i];
        float inR = _tempRightPtr[i];
        float outL = inL - dcInL + DC_BLOCKER_R * dcOutL;
        float outR = inR - dcInR + DC_BLOCKER_R * dcOutR;
        dcInL = inL;
        dcOutL = outL;
        dcInR = inR;
        dcOutR = outR;

        float dryL = (drySrcL ? drySrcL[i] : 0.0f) * _dryVolume;
        float dryR = (drySrcR ? drySrcR[i] : 0.0f) * _dryVolume;
        float wetL = outL * _wetVolume * (float)(gain * extraFade);
        float wetR = outR * _wetVolume * (float)(gain * extraFade);

        if (_isFadingIn){
            float rate = _fadeInCounter / (float)FADE_SAMPLE_NUM;
            wetL *= rate;
            wetR *= rate;
            _fadeInCounter++;
            if (_fadeInCounter >= FADE_SAMPLE_NUM){
                _isFadingIn = NO;
            }
        }

        leftBuf[i] = dryL + wetL;
        rightBuf[i] = dryR + wetR;
        gain += dGain;
        extraFade += dExtraFade;
    }

    _dcInL = dcInL;
    _dcOutL = dcOutL;
    _dcInR = dcInR;
    _dcOutR = dcOutR;
    _smoothedSpeed = speedEnd;
    _wetGain = gainEnd;
    [_ring advanceReadPtrSample:consumed];
    [_ring advanceDryPtrSample:numSamples];

    if (applyExtraFade){
        if (_fadeOutCounter >= numSamples){
            _fadeOutCounter -= numSamples;
        }else{
            _fadeOutCounter = 0;
        }
    }
}

-(void)processVariableRateState:(float *)leftBuf right:(float *)rightBuf samples:(UInt32)numSamples{
    [self processVariableRateBlock:leftBuf right:rightBuf samples:numSamples applyExtraFade:NO];
}

-(void)processNormalState:(float *)leftBuf right:(float *)rightBuf samples:(UInt32)numSamples{
    float *srcL = [_ring dryPtrLeft];
    float *srcR = [_ring dryPtrRight];
    if (srcL == NULL || srcR == NULL){
        memset(leftBuf, 0, sizeof(float) * numSamples);
        memset(rightBuf, 0, sizeof(float) * numSamples);
        return;
    }

    for (UInt32 i = 0; i < numSamples; i++){
        float sampleL = srcL[i];
        float sampleR = srcR[i];

        if (_isFadingIn){
            float rate = _fadeInCounter / (float)FADE_SAMPLE_NUM;
            sampleL *= rate;
            sampleR *= rate;
            _fadeInCounter++;
            if (_fadeInCounter >= FADE_SAMPLE_NUM){
                _isFadingIn = NO;
            }
        }

        leftBuf[i] = sampleL;
        rightBuf[i] = sampleR;
    }
    [_ring advanceReadPtrSample:numSamples];
    [_ring advanceDryPtrSample:numSamples];
    // Keep scratch gain/speed state aligned for a subsequent Stop deceleration.
    _smoothedSpeed = 1.0;
    _wetGain = 1.0;
}

-(BOOL)isStopActive{
    return _tableStopTimer != nil || _tableStopped;
}

// Catch up to the live edge only when Stop is not holding a playhead.
-(void)followLiveUnlessStopping{
    if (![self isStopActive]){
        [_ring follow];
    }
}

-(void)completeScratchStartFade{
    _subSamplePos = 0.0;
    _smoothedSpeed = 1.0;
    _wetGain = 1.0;
    _isScratching = YES;
    _isFadingOut = NO;
    _isFadingIn = YES;
    _fadeInCounter = 0;
    _isScratchStarting = NO;
    _fadeOutCounter = 0;
}

-(UInt32)processFadeOutForScratchStart:(float *)leftBuf right:(float *)rightBuf samples:(UInt32)numSamples{
    UInt32 n = (numSamples < _fadeOutCounter) ? numSamples : _fadeOutCounter;
    float *srcL = [_ring readPtrLeft];
    float *srcR = [_ring readPtrRight];
    float *drySrcL = [_ring dryPtrLeft];
    float *drySrcR = [_ring dryPtrRight];
    if (srcL == NULL || srcR == NULL){
        memset(leftBuf, 0, sizeof(float) * n);
        memset(rightBuf, 0, sizeof(float) * n);
        [self followLiveUnlessStopping];
        [self completeScratchStartFade];
        return n;
    }

    for (UInt32 i = 0; i < n; i++){
        float dryL = (drySrcL ? drySrcL[i] : 0.0f) * _dryVolume;
        float dryR = (drySrcR ? drySrcR[i] : 0.0f) * _dryVolume;
        float wetL = srcL[i] * _wetVolume;
        float wetR = srcR[i] * _wetVolume;
        float rate = _fadeOutCounter / (float)FADE_SAMPLE_NUM;
        wetL *= rate;
        wetR *= rate;
        _fadeOutCounter--;
        leftBuf[i] = dryL + wetL;
        rightBuf[i] = dryR + wetR;

        if (_fadeOutCounter == 0){
            [_ring advanceReadPtrSample:(SInt32)(i + 1)];
            [_ring advanceDryPtrSample:(SInt32)(i + 1)];
            [self followLiveUnlessStopping];
            [self completeScratchStartFade];
            return i + 1;
        }
    }

    [_ring advanceReadPtrSample:n];
    [_ring advanceDryPtrSample:n];
    return n;
}

-(UInt32)processFadeOutForScratchEnd:(float *)leftBuf right:(float *)rightBuf samples:(UInt32)numSamples{
    UInt32 n = (numSamples < _fadeOutCounter) ? numSamples : _fadeOutCounter;
    [self processVariableRateBlock:leftBuf right:rightBuf samples:n applyExtraFade:YES];

    if (_fadeOutCounter == 0){
        [self followLiveUnlessStopping];
        _subSamplePos = 0.0;
        if ([self isStopActive]){
            // Resume the Stop ramp that continued under the scratch.
            _speedRate = _tableStopped ? 0.0 : _tableStopSpeed;
            _smoothedSpeed = _speedRate;
            _wetGain = (_speedRate < STOPPED_SPEED_EPSILON) ? 0.0 : 1.0;
        }else{
            _smoothedSpeed = 1.0;
            _wetGain = 0.0;
        }
        _isScratching = NO;
        _isFadingOut = NO;
        _isFadingIn = YES;
        _fadeInCounter = 0;
        _isScratchEnding = NO;
    }
    return n;
}

-(void)processScratchOutput:(float *)leftBuf right:(float *)rightBuf samples:(UInt32)numSamples{
    if (_isFadingOut){
        UInt32 processed = 0;
        if (_isScratchStarting){
            processed = [self processFadeOutForScratchStart:leftBuf right:rightBuf samples:numSamples];
            if (processed < numSamples){
                [self processVariableRateState:&leftBuf[processed] right:&rightBuf[processed] samples:numSamples - processed];
            }
        }else if (_isScratchEnding){
            processed = [self processFadeOutForScratchEnd:leftBuf right:rightBuf samples:numSamples];
            if (!_isFadingOut && processed < numSamples){
                // Same callback may still have frames left after the fade ends.
                if ([self isStopActive]){
                    [self processVariableRateState:&leftBuf[processed] right:&rightBuf[processed] samples:numSamples - processed];
                }else{
                    [self processNormalState:&leftBuf[processed] right:&rightBuf[processed] samples:numSamples - processed];
                }
            }
        }
        return;
    }

    // Variable-rate path: scratch, Stop deceleration, or fully stopped platter.
    // Stop must not require _isScratching — tableStopTimer only updates stop speed.
    if (_isScratching || _tableStopped || _tableStopTimer != nil){
        [self processVariableRateState:leftBuf right:rightBuf samples:numSamples];
    }else{
        [self processNormalState:leftBuf right:rightBuf samples:numSamples];
    }
}

-(void)turnTableSpeedRateChanged:(double)newSpeedRate{
    // Stop is not cancelled by platter input: scratch owns audible speed while held,
    // and the Stop ramp continues underneath via _tableStopSpeed.
    BOOL pressing = [_turnTableView isScratching];
    _speedRate = newSpeedRate;

    if (_isScratchEnding && pressing){
        _isScratchEnding = NO;
        _isScratchStarting = YES;
        _isFadingOut = YES;
        _fadeOutCounter = FADE_SAMPLE_NUM;
        return;
    }

    if (_isScratchStarting && !pressing){
        _isScratchStarting = NO;
        _isScratchEnding = YES;
        _isFadingOut = YES;
        _fadeOutCounter = FADE_SAMPLE_NUM;
        return;
    }

    if (!_isScratching && !_isFadingOut && pressing){
        _isScratchStarting = YES;
        _isFadingOut = YES;
        _fadeOutCounter = FADE_SAMPLE_NUM;
        return;
    }

    if (_isScratching && !_isFadingOut && !pressing){
        _isScratchEnding = YES;
        _isFadingOut = YES;
        _fadeOutCounter = FADE_SAMPLE_NUM;
        return;
    }
}

- (OSStatus) outCallback:(AudioUnitRenderActionFlags *)ioActionFlags inTimeStamp:(const AudioTimeStamp *) inTimeStamp inBusNumber:(UInt32) inBusNumber inNumberFrames:(UInt32)inNumberFrames ioData:(AudioBufferList *)ioData{
    static BOOL printedNumFrames = NO;
    if (!printedNumFrames){
        NSLog(@"outCallback NumFrames = %d", inNumberFrames);
        printedNumFrames = YES;
    }

    if (![_ae isPlaying]){
        UInt32 sampleNum = inNumberFrames;
        float *pLeft = (float *)ioData->mBuffers[0].mData;
        float *pRight = (float *)ioData->mBuffers[1].mData;
        bzero(pLeft,sizeof(float)*sampleNum );
        bzero(pRight,sizeof(float)*sampleNum );
        NSLog(@"ae not playing");
        return noErr;
    }

    if ([_ring isShortage]){
        UInt32 sampleNum = inNumberFrames;
        float *pLeft = (float *)ioData->mBuffers[0].mData;
        float *pRight = (float *)ioData->mBuffers[1].mData;
        bzero(pLeft,sizeof(float)*sampleNum );
        bzero(pRight,sizeof(float)*sampleNum );
        return noErr;
    }

    if (![_ring readPtrLeft] || ![_ring readPtrRight]){
        NSLog(@"no enough buffer on read");
        UInt32 sampleNum = inNumberFrames;
        float *pLeft = (float *)ioData->mBuffers[0].mData;
        float *pRight = (float *)ioData->mBuffers[1].mData;
        bzero(pLeft, sizeof(float)*sampleNum );
        bzero(pRight, sizeof(float)*sampleNum );
        return noErr;
    }

    float *dstL = (float *)ioData->mBuffers[0].mData;
    float *dstR = (float *)ioData->mBuffers[1].mData;

    [self processScratchOutput:dstL right:dstR samples:inNumberFrames];
    return noErr;
}

// The engine has stopped its audio callbacks before this notification.
- (void)audioEngineDidRebuildPipeline:(AudioEngine *)engine{
    _ring = [[RingBuffer alloc] initWithSampleRate:[engine sampleRate]];
    [_turnTableView setRingBuffer:_ring];
    [self resetScratchState];
}

- (IBAction)dryVolumeChanged:(id)sender {
    _dryVolume = _sliderDry.floatValue;
}

- (IBAction)startStopButtonClicked:(id)sender {
    if (_btnStop.state == NSControlStateValueOn){
        if (_tableStopTimer){
            [_tableStopTimer invalidate];
            _tableStopTimer = nil;
        }

        _tableStopped = NO;
        _tableStopSpeed = 1.0;
        _speedRate = 1.0;
        [self resetScratchState];
        _isFadingIn = YES;
        _fadeInCounter = 0;
        [_ring follow];
        [_btnStop setTitle:@"[S]top"];
    }else{
        if (_tableStopTimer){
            [_tableStopTimer invalidate];
            _tableStopTimer = nil;
        }
        // Decelerate via _tableStopSpeed; leave the scratch fade state machine alone.
        // Scratch may still own audible _speedRate while this ramp continues underneath.
        _isScratchStarting = NO;
        _isScratchEnding = NO;
        _isFadingOut = NO;
        _isScratching = NO;
        _isFadingIn = NO;
        _tableStopped = NO;
        _tableStopSpeed = (_speedRate > 0.0) ? _speedRate : 1.0;
        _speedRate = _tableStopSpeed;
        _tableStopTimer = [NSTimer scheduledTimerWithTimeInterval:0.01 target:self selector:@selector(tableStopTimer:) userInfo:nil repeats:YES];
        [_btnStop setTitle:@"[S]tart"];
    }
}

- (void)tableStopTimer:(NSTimer *)t {
    if (_tableStopSpeed < 0.01f){
        _tableStopSpeed = 0.0f;
        [_tableStopTimer invalidate];
        _tableStopTimer = nil;
        _tableStopped = YES;
    }else{
        _tableStopSpeed -= 0.02;
    }

    // Scratch owns audible speed while the platter is held or mid fade handoff.
    BOOL scratchOwnsSpeed = [_turnTableView isScratching] || _isScratching || _isScratchStarting || _isScratchEnding;
    if (!scratchOwnsSpeed){
        _speedRate = _tableStopSpeed;
    }
}

-(void)turnTableSpeedRateChanged{
    double newSpeedRate = [_turnTableView speedRate];
    if (![_turnTableView isScratching]){
        if ([self isStopActive]){
            // Released into an active Stop: resume the underlying decelerated speed.
            newSpeedRate = _tableStopped ? 0.0 : _tableStopSpeed;
            [_turnTableView setSpeedRate:newSpeedRate];
        }else if (newSpeedRate == 0.0){
            newSpeedRate = 1.0;
            [_turnTableView setSpeedRate:newSpeedRate];
        }
    }
    [self turnTableSpeedRateChanged:newSpeedRate];
}

-(void)terminate{
    [_ae shutdown];
}
@end
