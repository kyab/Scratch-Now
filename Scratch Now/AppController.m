//
//  AppController.m
//  Scratch Now
//
//  Created by kyab on 2021/06/19.
//

#import "AppController.h"
#include <math.h>
#include <string.h>

#define FADE_SAMPLE_NUM 500
#define FADE_SAMPLE_NUM_GLOBAL 3000
#define SPEED_SMOOTH_ALPHA (1.0 / 128.0)
#define GAIN_SMOOTH_ALPHA (1.0 / 256.0)
#define DC_BLOCKER_R (0.995f)
#define GAIN_SLOPE (4.0)
#define STOPPED_SPEED_EPSILON (1.0e-4)

static BOOL sIsGlobalFadeIn = YES;
static UInt32 sGlobalFadeInCounter = 0;
static BOOL sIsGlobalFadeOut = NO;
static UInt32 sGlobalFadeOutCounter = 0;
static BOOL sDidScheduleTerminationFinish = NO;

@interface AppController ()
- (void)scheduleFinishAppTermination;
- (void)finishAppTermination;
@end

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
    _isReturningToLive = NO;
    _isFadingOut = NO;
    _isFadingIn = NO;
    _isScratching = NO;
    _fadeOutCounter = 0;
    _fadeInCounter = 0;
    _smoothedSpeed = 1.0;
    _subSamplePos = 0.0;
    _wetGain = 1.0;
    _dcPrevInL = 0.0f;
    _dcPrevOutL = 0.0f;
    _dcPrevInR = 0.0f;
    _dcPrevOutR = 0.0f;
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
}

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
    float dcPrevInL = _dcPrevInL;
    float dcPrevOutL = _dcPrevOutL;
    float dcPrevInR = _dcPrevInR;
    float dcPrevOutR = _dcPrevOutR;

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
        float outL = inL - dcPrevInL + DC_BLOCKER_R * dcPrevOutL;
        float outR = inR - dcPrevInR + DC_BLOCKER_R * dcPrevOutR;
        dcPrevInL = inL;
        dcPrevOutL = outL;
        dcPrevInR = inR;
        dcPrevOutR = outR;

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

    _dcPrevInL = dcPrevInL;
    _dcPrevOutL = dcPrevOutL;
    _dcPrevInR = dcPrevInR;
    _dcPrevOutR = dcPrevOutR;
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
    // Normal playback does not run the DC blocker. Seed it from the last
    // audible sample so a later switch to variable-rate (Stop) is continuous.
    if (numSamples > 0){
        _dcPrevInL = leftBuf[numSamples - 1];
        _dcPrevOutL = _dcPrevInL;
        _dcPrevInR = rightBuf[numSamples - 1];
        _dcPrevOutR = _dcPrevInR;
    }
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

-(UInt32)processFadeOutForReturnToLive:(float *)leftBuf right:(float *)rightBuf samples:(UInt32)numSamples{
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
            _speedRate = 1.0;
            _smoothedSpeed = 1.0;
            _wetGain = 0.0;
        }
        _isScratching = NO;
        _isFadingOut = NO;
        _isFadingIn = YES;
        _fadeInCounter = 0;
        _isReturningToLive = NO;
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
        }else if (_isReturningToLive){
            processed = [self processFadeOutForReturnToLive:leftBuf right:rightBuf samples:numSamples];
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
    BOOL isPlatterTouching = [_turnTableView isPlatterTouching];
    _speedRate = newSpeedRate;

    if (_isReturningToLive && isPlatterTouching){
        _isReturningToLive = NO;
        _isScratchStarting = YES;
        _isFadingOut = YES;
        _fadeOutCounter = FADE_SAMPLE_NUM;
        return;
    }

    if (_isScratchStarting && !isPlatterTouching){
        _isScratchStarting = NO;
        _isReturningToLive = YES;
        _isFadingOut = YES;
        _fadeOutCounter = FADE_SAMPLE_NUM;
        return;
    }

    if (!_isScratching && !_isFadingOut && isPlatterTouching){
        if (_tableStopped){
            _isScratching = YES;
            _smoothedSpeed = 0.0;
        }else{
            _isScratchStarting = YES;
            _isFadingOut = YES;
            _fadeOutCounter = FADE_SAMPLE_NUM;
        }
        return;
    }

    if (_isScratching && !_isFadingOut && !isPlatterTouching){
        _isReturningToLive = YES;
        _isFadingOut = YES;
        _fadeOutCounter = FADE_SAMPLE_NUM;
        return;
    }
}

- (OSStatus) outCallback:(AudioUnitRenderActionFlags *)ioActionFlags inTimeStamp:(const AudioTimeStamp *) inTimeStamp inBusNumber:(UInt32) inBusNumber inNumberFrames:(UInt32)inNumberFrames ioData:(AudioBufferList *)ioData{
    static BOOL printedNumFrames = NO;
    if (!printedNumFrames){
        NSLog(@"[OUT CALLBACK] printedNumFrames = %d", printedNumFrames);
        printedNumFrames = YES;
    }

    if ([_ring isShortage]){
        UInt32 sampleNum = inNumberFrames;
        float *pLeft = (float *)ioData->mBuffers[0].mData;
        float *pRight = (float *)ioData->mBuffers[1].mData;
        bzero(pLeft,sizeof(float)*sampleNum );
        bzero(pRight,sizeof(float)*sampleNum );
        NSLog(@"[OUT CALLBACK] buffer shortage");
        if (sIsGlobalFadeOut){
            [self scheduleFinishAppTermination];
        }else{
            sIsGlobalFadeIn = YES;
            sGlobalFadeInCounter = 0;
        }
        return noErr;
    }

    if (![_ring readPtrLeft] || ![_ring readPtrRight]){
        NSLog(@"[OUT CALLBACK] no enough buffer on read");
        UInt32 sampleNum = inNumberFrames;
        float *pLeft = (float *)ioData->mBuffers[0].mData;
        float *pRight = (float *)ioData->mBuffers[1].mData;
        bzero(pLeft, sizeof(float) * sampleNum);
        bzero(pRight, sizeof(float) * sampleNum);
        if (sIsGlobalFadeOut){
            [self scheduleFinishAppTermination];
        }else{
            sIsGlobalFadeIn = YES;
            sGlobalFadeInCounter = 0;
        }
        return noErr;
    }

    float *dstL = (float *)ioData->mBuffers[0].mData;
    float *dstR = (float *)ioData->mBuffers[1].mData;

    [self processScratchOutput:dstL right:dstR samples:inNumberFrames];

    if (sIsGlobalFadeIn){
        for (UInt32 i = 0; i < inNumberFrames; i++){
            if (sGlobalFadeInCounter >= FADE_SAMPLE_NUM_GLOBAL){
                sIsGlobalFadeIn = NO;
                sGlobalFadeInCounter = 0;
                break;
            }
            float rate = sGlobalFadeInCounter / (float)FADE_SAMPLE_NUM_GLOBAL;
            dstL[i] *= rate;
            dstR[i] *= rate;
            sGlobalFadeInCounter++;
        }
        if (sGlobalFadeInCounter >= FADE_SAMPLE_NUM_GLOBAL){
            sIsGlobalFadeIn = NO;
            sGlobalFadeInCounter = 0;
        }
        NSLog(@"[OUT CALLBACK] globalFadeInCounter = %d", sGlobalFadeInCounter);
    }

    if (sIsGlobalFadeOut){
        for (UInt32 i = 0; i < inNumberFrames; i++){
            if (sGlobalFadeOutCounter == 0){
                break;
            }
            float rate = sGlobalFadeOutCounter / (float)FADE_SAMPLE_NUM_GLOBAL;
            dstL[i] *= rate;
            dstR[i] *= rate;
            sGlobalFadeOutCounter--;
        }
        if (sGlobalFadeOutCounter == 0){
            [self scheduleFinishAppTermination];
        }
    }
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
    if (_btnStop.state == NSControlStateValueOn){ //"Start"
        BOOL isStopRampInProgress = (_tableStopTimer != nil);
        if (_tableStopTimer){
            [_tableStopTimer invalidate];
            _tableStopTimer = nil;
        }
        _tableStopped = NO;
        _tableStopSpeed = 1.0;

        if (isStopRampInProgress && !_isFadingOut){
            _isScratchStarting = NO;
            _isReturningToLive = YES;
            _isFadingOut = YES;
            _fadeOutCounter = FADE_SAMPLE_NUM;
        }else if (!_isFadingOut){
            // Fully stopped
            _speedRate = 1.0;
            [self resetScratchState];
            _isFadingIn = YES;
            _fadeInCounter = 0;
            [_ring follow];
        }
        [_btnStop setTitle:@"[S]top"];
    }else{      //"Stop"
        if (_tableStopTimer){
            [_tableStopTimer invalidate];
            _tableStopTimer = nil;
        }
        // Decelerate via _tableStopSpeed; leave the scratch fade state machine alone.
        // Scratch may still own audible _speedRate while this ramp continues underneath.
        _isScratchStarting = NO;
        _isReturningToLive = NO;
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
    BOOL scratchOwnsSpeed = [_turnTableView isPlatterTouching] || _isScratching || _isScratchStarting || _isReturningToLive;
    if (!scratchOwnsSpeed){
        _speedRate = _tableStopSpeed;
    }
}

-(void)turnTableSpeedRateChanged{
    double newSpeedRate = [_turnTableView speedRate];
    if (![_turnTableView isPlatterTouching]){
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

-(void)scheduleFinishAppTermination{
    if (sDidScheduleTerminationFinish){
        return;
    }
    sDidScheduleTerminationFinish = YES;
    sIsGlobalFadeOut = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self finishAppTermination];
    });
}

-(void)finishAppTermination{
    [_ae shutdown];
    [NSApp replyToApplicationShouldTerminate:YES];
}

-(void)terminate{
    if (sDidScheduleTerminationFinish || sIsGlobalFadeOut){
        return;
    }
    if (!_ae || ![_ae isPlaying]){
        [self finishAppTermination];
        return;
    }

    sIsGlobalFadeOut = YES;
    if (sIsGlobalFadeIn){
        sGlobalFadeOutCounter = sGlobalFadeInCounter;
        sIsGlobalFadeIn = NO;
        if (sGlobalFadeOutCounter == 0){
            [self scheduleFinishAppTermination];
        }
    }else{
        sGlobalFadeOutCounter = FADE_SAMPLE_NUM_GLOBAL;
    }
}
@end
