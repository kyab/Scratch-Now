//
//  TurnTable.m
//  Scratch Now
//

#import "TurnTable.h"
#include <math.h>
#include <string.h>
#include <stdlib.h>
#include <time.h>
#include <mach/mach_time.h>

#define FADE_SAMPLE_NUM 500
// Longer than the ~6-10 ms platter update interval so its steps are not heard as pitch steps.
#define SPEED_SMOOTH_TAU_SEC 0.010
#define GAIN_SMOOTH_ALPHA (1.0 / 256.0)
#define DC_BLOCKER_R (0.995f)
#define GAIN_SLOPE (4.0)
#define STOPPED_SPEED_EPSILON (1.0e-4)

#define TABLE_STOP_TIMER_SEC 0.01
#define COAST_TIMER_SEC 0.01

// Match the Stop ramp from 1.0x: -0.02 / 10ms until < 0.01 (~0.5s).
// EMA |v|=1 -> 0.01 in 0.5s => tau = 0.5 / -ln(0.01). = 0.1086
//#define COAST_TAU_SEC 0.1086
#define COAST_TAU_SEC 0.1
#define COAST_FORWARD_TAU_SEC 0.1086

#define COAST_END_EPSILON 0.05
#define COAST_SKIP_EPSILON 0.80
#define COAST_FORWARD_SKIP_EPSILON 0.40

#define SPEED_LOG_CAPACITY (1 << 16)
#define SPEED_LOG_DRAIN_TIMER_SEC 0.02
#define CAPTURE_CAPACITY_FRAMES (1 << 18)

static inline float cubicInterpolate(float y0, float y1, float y2, float y3, double mu) {
    double mu2 = mu * mu;
    double a0 = (double)y3 - (double)y2 - (double)y0 + (double)y1;
    double a1 = (double)y0 - (double)y1 - a0;
    double a2 = (double)y2 - (double)y0;
    double a3 = (double)y1;
    return (float)((mu * mu2 * a0) + (mu2 * a1) + (mu * a2) + a3);
}

static void writeFloatWavHeader(FILE *f, double sampleRate, uint64_t frames){
    const uint16_t channels = 2;
    const uint16_t bitsPerSample = 32;
    const uint16_t formatIEEEFloat = 3;
    uint32_t rate = (uint32_t)sampleRate;
    uint32_t blockAlign = channels * bitsPerSample / 8;
    uint32_t byteRate = rate * blockAlign;
    uint32_t dataBytes = (uint32_t)(frames * blockAlign);
    uint32_t riffBytes = 36 + dataBytes;
    uint32_t fmtBytes = 16;
    uint8_t h[44];
    memcpy(h + 0, "RIFF", 4);
    memcpy(h + 4, &riffBytes, 4);
    memcpy(h + 8, "WAVEfmt ", 8);
    memcpy(h + 16, &fmtBytes, 4);
    memcpy(h + 20, &formatIEEEFloat, 2);
    memcpy(h + 22, &channels, 2);
    memcpy(h + 24, &rate, 4);
    memcpy(h + 28, &byteRate, 4);
    uint16_t blockAlign16 = (uint16_t)blockAlign;
    memcpy(h + 32, &blockAlign16, 2);
    memcpy(h + 34, &bitsPerSample, 2);
    memcpy(h + 36, "data", 4);
    memcpy(h + 40, &dataBytes, 4);
    fseek(f, 0, SEEK_SET);
    fwrite(h, 1, sizeof(h), f);
    fseek(f, 0, SEEK_END);
}

@implementation TurnTable

-(instancetype)initWithSampleRate:(double)sampleRate{
    self = [super init];
    if (self){
        _ring = [[RingBuffer alloc] initWithSampleRate:sampleRate];
        [self setUpSpeedLogIfEnabledWithSampleRate:sampleRate];
        [self updateSpeedSmoothAlphaForSampleRate:sampleRate];
        _speedRate = 1.0;
        _tableStopSpeed = 1.0;
        _dryVolume = 0.0;
        _wetVolume = 1.0;
        _autoFollow = YES;
        _platterSpeedRate = 1.0;
        [self resetScratchState];
    }
    return self;
}

-(void)dealloc{
    [_speedLogTimer invalidate];
    free(_speedLog);
    if (_captureFile != NULL) fclose(_captureFile);
    free(_captureBuf);
}

#pragma mark - Speed log

-(void)setUpSpeedLogIfEnabledWithSampleRate:(double)sampleRate{
    const char *env = getenv("SCRATCH_SPEED_LOG");
    if (env == NULL || strcmp(env, "1") != 0){
        return;
    }
    _speedLogCapacity = SPEED_LOG_CAPACITY;
    _speedLog = calloc(_speedLogCapacity, sizeof(SpeedLogRecord));
    atomic_init(&_speedLogWriteCount, 0);
    atomic_init(&_speedLogReadCount, 0);
    atomic_init(&_speedLogDroppedCount, 0);
    _speedLogReportedDroppedCount = 0;

    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    _speedLogSecPerHostTick = (double)timebase.numer / (double)timebase.denom * 1.0e-9;
    _speedLogBaseHostTime = mach_absolute_time();
    _speedLogBaseEpochSec = [[NSDate date] timeIntervalSince1970];

    _speedLogTimer = [NSTimer timerWithTimeInterval:SPEED_LOG_DRAIN_TIMER_SEC target:self selector:@selector(onSpeedLogTimer:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_speedLogTimer forMode:NSRunLoopCommonModes];
    NSLog(@"[SpeedLog] enabled (capacity = %u records)", _speedLogCapacity);
    [self setUpOutputCaptureWithSampleRate:sampleRate];
}

-(void)setUpOutputCaptureWithSampleRate:(double)sampleRate{
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *name = [NSString stringWithFormat:@"scratch_output_%@.wav", [formatter stringFromDate:[NSDate date]]];
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
    _captureFile = fopen(path.fileSystemRepresentation, "wb");
    if (_captureFile == NULL){
        NSLog(@"[SpeedLog] WARNING could not open output capture file %@", path);
        return;
    }
    _captureSampleRate = sampleRate;
    _captureFileFrames = 0;
    writeFloatWavHeader(_captureFile, _captureSampleRate, 0);

    _captureCapacityFrames = CAPTURE_CAPACITY_FRAMES;
    _captureBuf = calloc((size_t)_captureCapacityFrames * 2, sizeof(float));
    atomic_init(&_captureWriteFrames, 0);
    atomic_init(&_captureReadFrames, 0);
    atomic_init(&_captureDroppedFrames, 0);
    _captureReportedDroppedFrames = 0;
    NSLog(@"[SpeedLog] output capture: path = %@, sampleRate = %f", path, sampleRate);
}

-(void)captureOutputLeft:(const float *)leftBuf right:(const float *)rightBuf frames:(UInt32)numFrames{
    if (_captureBuf == NULL) return;
    uint64_t w = atomic_load_explicit(&_captureWriteFrames, memory_order_relaxed);
    uint64_t r = atomic_load_explicit(&_captureReadFrames, memory_order_acquire);
    if (w - r + numFrames > _captureCapacityFrames){
        atomic_fetch_add_explicit(&_captureDroppedFrames, numFrames, memory_order_relaxed);
        return;
    }
    for (UInt32 i = 0; i < numFrames; i++){
        size_t idx = (size_t)((w + i) % _captureCapacityFrames) * 2;
        _captureBuf[idx] = leftBuf[i];
        _captureBuf[idx + 1] = rightBuf[i];
    }
    atomic_store_explicit(&_captureWriteFrames, w + numFrames, memory_order_release);
}

-(void)drainOutputCapture{
    if (_captureBuf == NULL) return;
    uint64_t r = atomic_load_explicit(&_captureReadFrames, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&_captureWriteFrames, memory_order_acquire);
    if (w == r) return;
    while (r < w){
        uint64_t start = r % _captureCapacityFrames;
        uint64_t n = w - r;
        if (start + n > _captureCapacityFrames) n = _captureCapacityFrames - start;
        fwrite(&_captureBuf[start * 2], sizeof(float) * 2, (size_t)n, _captureFile);
        r += n;
        _captureFileFrames += n;
    }
    atomic_store_explicit(&_captureReadFrames, r, memory_order_release);
    writeFloatWavHeader(_captureFile, _captureSampleRate, _captureFileFrames);
    fflush(_captureFile);

    uint64_t dropped = atomic_load_explicit(&_captureDroppedFrames, memory_order_relaxed);
    if (dropped != _captureReportedDroppedFrames){
        NSLog(@"[SpeedLog] WARNING dropped output capture frames total = %llu", dropped);
        _captureReportedDroppedFrames = dropped;
    }
}

-(void)recordSpeedLogStart:(double)speedStart end:(double)speedEnd samples:(UInt32)numSamples{
    if (_speedLog == NULL) return;
    uint64_t w = atomic_load_explicit(&_speedLogWriteCount, memory_order_relaxed);
    uint64_t r = atomic_load_explicit(&_speedLogReadCount, memory_order_acquire);
    if (w - r >= _speedLogCapacity){
        atomic_fetch_add_explicit(&_speedLogDroppedCount, 1, memory_order_relaxed);
        return;
    }
    SpeedLogRecord *rec = &_speedLog[w % _speedLogCapacity];
    rec->hostTime = mach_absolute_time();
    rec->speedStart = speedStart;
    rec->speedEnd = speedEnd;
    rec->numSamples = numSamples;
    rec->outputFrame = _outputFrameCount;
    atomic_store_explicit(&_speedLogWriteCount, w + 1, memory_order_release);
}

-(NSString *)speedLogTimestampForHostTime:(uint64_t)hostTime{
    double epochSec = _speedLogBaseEpochSec + (double)(int64_t)(hostTime - _speedLogBaseHostTime) * _speedLogSecPerHostTick;
    time_t whole = (time_t)floor(epochSec);
    int micros = (int)((epochSec - (double)whole) * 1.0e6);
    if (micros > 999999) micros = 999999;
    struct tm local;
    localtime_r(&whole, &local);
    char dateBuf[32];
    strftime(dateBuf, sizeof(dateBuf), "%Y-%m-%d %H:%M:%S", &local);
    long offsetMin = local.tm_gmtoff / 60;
    char sign = (offsetMin < 0) ? '-' : '+';
    if (offsetMin < 0) offsetMin = -offsetMin;
    return [NSString stringWithFormat:@"%s.%06d%c%02ld:%02ld", dateBuf, micros, sign, offsetMin / 60, offsetMin % 60];
}

-(void)onSpeedLogTimer:(NSTimer *)t{
    uint64_t r = atomic_load_explicit(&_speedLogReadCount, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&_speedLogWriteCount, memory_order_acquire);
    for (; r < w; r++){
        SpeedLogRecord rec = _speedLog[r % _speedLogCapacity];
        NSLog(@"[SpeedLog] speedStart = %f, speedEnd = %f, samples = %u, outputFrame = %llu\nTimestamp: %@",
              rec.speedStart, rec.speedEnd, rec.numSamples, rec.outputFrame, [self speedLogTimestampForHostTime:rec.hostTime]);
    }
    atomic_store_explicit(&_speedLogReadCount, r, memory_order_release);
    [self drainOutputCapture];

    uint64_t dropped = atomic_load_explicit(&_speedLogDroppedCount, memory_order_relaxed);
    if (dropped != _speedLogReportedDroppedCount){
        NSLog(@"[SpeedLog] WARNING dropped records total = %llu", dropped);
        _speedLogReportedDroppedCount = dropped;
    }
}

-(void)rebuildWithSampleRate:(double)sampleRate{
    _ring = [[RingBuffer alloc] initWithSampleRate:sampleRate];
    [self updateSpeedSmoothAlphaForSampleRate:sampleRate];
    [self resetScratchState];
}

-(void)updateSpeedSmoothAlphaForSampleRate:(double)sampleRate{
    // Per-sample one-pole EMA coefficient for time constant tau: 1 - exp(-1 / (tau * fs)).
    _speedSmoothAlpha = 1.0 - exp(-1.0 / (SPEED_SMOOTH_TAU_SEC * sampleRate));
    if (_speedLog != NULL){
        NSLog(@"[SpeedLog] params SPEED_SMOOTH_TAU_SEC = %f, speedSmoothAlpha = %.8f, sampleRate = %f",
              SPEED_SMOOTH_TAU_SEC, _speedSmoothAlpha, sampleRate);
    }
}

-(RingBuffer *)ring{
    return _ring;
}

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

#pragma mark - Input

-(void)processInputLeft:(const float *)leftBuf right:(const float *)rightBuf frames:(UInt32)numFrames{
    memcpy([_ring writePtrLeft], leftBuf, sizeof(float) * numFrames);
    memcpy([_ring writePtrRight], rightBuf, sizeof(float) * numFrames);
    [_ring advanceWritePtrSample:numFrames];
}

#pragma mark - Output

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
        speedEnd += (targetSpeed - speedEnd) * _speedSmoothAlpha;
    }
    [self recordSpeedLogStart:speedStart end:speedEnd samples:numSamples];

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

    // Dry: independent 1x realtime pointer.
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
    float *srcL = [_ring readPtrLeft];
    float *srcR = [_ring readPtrRight];
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

-(void)followLiveUnlessStopping{
    if (_autoFollow && ![self isStopActive]){
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

-(void)handleSpeedRateChange:(double)newSpeedRate underManualControl:(BOOL)isUnderManualControl{
    // Stop is not cancelled by platter input: scratch owns audible speed while held,
    // and the Stop ramp continues underneath via _tableStopSpeed.
    _speedRate = newSpeedRate;

    if (_isReturningToLive && isUnderManualControl){
        _isReturningToLive = NO;
        _isScratchStarting = YES;
        _isFadingOut = YES;
        _fadeOutCounter = FADE_SAMPLE_NUM;
        return;
    }

    if (_isScratchStarting && !isUnderManualControl){
        _isScratchStarting = NO;
        _isReturningToLive = YES;
        _isFadingOut = YES;
        _fadeOutCounter = FADE_SAMPLE_NUM;
        return;
    }

    if (!_isScratching && !_isFadingOut && isUnderManualControl){
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

    if (_isScratching && !_isFadingOut && !isUnderManualControl){
        _isReturningToLive = YES;
        _isFadingOut = YES;
        _fadeOutCounter = FADE_SAMPLE_NUM;
        return;
    }
}

-(BOOL)isUnderManualControl{
    return _isScratchingByPlatter || _isCoasting;
}

-(void)updateSpeedFromPlatter{
    BOOL isUnderManualControl = [self isUnderManualControl];
    double newSpeedRate = isUnderManualControl ? _platterSpeedRate : 1.0;
    if (!isUnderManualControl){
        if ([self isStopActive]){
            // Released into an active Stop: resume the underlying decelerated speed.
            newSpeedRate = _tableStopped ? 0.0 : _tableStopSpeed;
        }else if (newSpeedRate == 0.0){
            newSpeedRate = 1.0;
        }
    }
    [self handleSpeedRateChange:newSpeedRate underManualControl:isUnderManualControl];
}

-(void)processOutputLeft:(float *)leftBuf right:(float *)rightBuf frames:(UInt32)numFrames{
    [self renderOutputLeft:leftBuf right:rightBuf frames:numFrames];
    [self captureOutputLeft:leftBuf right:rightBuf frames:numFrames];
    _outputFrameCount += numFrames;
}

-(void)renderOutputLeft:(float *)leftBuf right:(float *)rightBuf frames:(UInt32)numFrames{
    if ([_ring isShortage]){
        bzero(leftBuf, sizeof(float) * numFrames);
        bzero(rightBuf, sizeof(float) * numFrames);
        return;
    }

    if (![_ring readPtrLeft] || ![_ring readPtrRight]){
        NSLog(@"no enough buffer on read");
        bzero(leftBuf, sizeof(float) * numFrames);
        bzero(rightBuf, sizeof(float) * numFrames);
        return;
    }

    [self updateSpeedFromPlatter];

    if (_isFadingOut){
        UInt32 processed = 0;
        if (_isScratchStarting){
            processed = [self processFadeOutForScratchStart:leftBuf right:rightBuf samples:numFrames];
            if (processed < numFrames){
                [self processVariableRateState:&leftBuf[processed] right:&rightBuf[processed] samples:numFrames - processed];
            }
        }else if (_isReturningToLive){
            processed = [self processFadeOutForReturnToLive:leftBuf right:rightBuf samples:numFrames];
            if (!_isFadingOut && processed < numFrames){
                // Same callback may still have frames left after the fade ends.
                if ([self isStopActive]){
                    [self processVariableRateState:&leftBuf[processed] right:&rightBuf[processed] samples:numFrames - processed];
                }else{
                    [self processNormalState:&leftBuf[processed] right:&rightBuf[processed] samples:numFrames - processed];
                }
            }
        }
        return;
    }

    // Variable-rate path: scratch, Stop deceleration, or fully stopped platter.
    // Stop must not require _isScratching — tableStopTimer only updates stop speed.
    if (_isScratching || _tableStopped || _tableStopTimer != nil){
        [self processVariableRateState:leftBuf right:rightBuf samples:numFrames];
    }else{
        [self processNormalState:leftBuf right:rightBuf samples:numFrames];
    }
}

#pragma mark - Transport

-(void)start{
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
        if (_autoFollow){
            [_ring follow];
        }
    }
}

-(void)stop{
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
    _tableStopTimer = [NSTimer scheduledTimerWithTimeInterval:TABLE_STOP_TIMER_SEC target:self selector:@selector(onTableStopTimer:) userInfo:nil repeats:YES];
}

-(void)onTableStopTimer:(NSTimer *)t{
    if (_tableStopSpeed < 0.01f){
        _tableStopSpeed = 0.0f;
        [_tableStopTimer invalidate];
        _tableStopTimer = nil;
        _tableStopped = YES;
    }else{
        _tableStopSpeed -= 0.02;
    }

    // Scratch owns audible speed while the platter is held or mid fade handoff.
    BOOL scratchOwnsSpeed = [self isUnderManualControl] || _isScratching || _isScratchStarting || _isReturningToLive;
    if (!scratchOwnsSpeed){
        _speedRate = _tableStopSpeed;
    }
}

-(void)follow{
    [_ring follow];
}

-(void)setAutoFollow:(Boolean)autoFollow{
    _autoFollow = autoFollow;
}

-(void)setDryVolume:(float)dryVolume{
    _dryVolume = dryVolume;
}

#pragma mark - Platter input

-(void)stopCoastTimer{
    [_coastTimer invalidate];
    _coastTimer = nil;
}

-(void)endPlatterScratch{
    [self stopCoastTimer];
    _isCoasting = NO;
    _isScratchingByPlatter = NO;
    _platterSpeedRate = 1.0;
}

-(void)beginCoastFromSpeed:(double)speedRate{
    _platterSpeedRate = speedRate;
    _isCoasting = YES;
    _isScratchingByPlatter = NO;
    _coastTargetSpeed = (speedRate > 0.0) ? 1.0 : 0.0;
    _prevCoastSec = [NSProcessInfo processInfo].systemUptime;
    [self stopCoastTimer];
    _coastTimer = [NSTimer timerWithTimeInterval:COAST_TIMER_SEC target:self selector:@selector(onCoastTimer:) userInfo:nil repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:_coastTimer forMode:NSRunLoopCommonModes];
}

-(void)onCoastTimer:(NSTimer *)t{
    NSTimeInterval nowSec = [NSProcessInfo processInfo].systemUptime;
    double dt = nowSec - _prevCoastSec;
    if (dt <= 0.0){
        return;
    }

    // Forward release eases back to normal playback speed, backward release
    // decays to a standstill. Both approach the target asymptotically, so the
    // coast ends once it is within COAST_END_EPSILON of it.
    double tau = (_coastTargetSpeed == 1.0) ? COAST_FORWARD_TAU_SEC : COAST_TAU_SEC;
    double alpha = 1.0 - exp(-dt / tau);
    _platterSpeedRate += (_coastTargetSpeed - _platterSpeedRate) * alpha;
    if (fabs(_platterSpeedRate - _coastTargetSpeed) < COAST_END_EPSILON){
        [self endPlatterScratch];
        return;
    }
    _prevCoastSec = nowSec;
}

-(void)beginScratch{
    [self stopCoastTimer];
    _platterSpeedRate = 0.0;
    _isCoasting = NO;
    _isScratchingByPlatter = YES;
}

-(void)updateScratchSpeed:(double)speedRate{
    _platterSpeedRate = speedRate;
}

-(void)endScratchWithReleaseSpeed:(double)speedRate{
    if (speedRate == 0.0
        || speedRate == 1.0
        || (speedRate > 0.0 && speedRate <= COAST_FORWARD_SKIP_EPSILON)
        || (speedRate < 0.0 && speedRate > -COAST_SKIP_EPSILON)){
        [self endPlatterScratch];
    }else{
        [self beginCoastFromSpeed:speedRate];
    }
}

@end
