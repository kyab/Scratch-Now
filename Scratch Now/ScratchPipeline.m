//
//  ScratchPipeline.m
//  Scratch Now
//

#import "ScratchPipeline.h"
#import <math.h>

// Upper bound for a single render block. Production uses 32 frames; offline tests
// may use larger blocks. The temp resample scratch buffers are sized to this.
#define SCRATCH_PIPELINE_MAX_BLOCK_FRAMES 8192

@implementation ScratchPipeline {
    RingBuffer *_ring;
    MiniFaderIn *_miniFaderIn;

    double _sampleRate;
    double _speedRate;
    BOOL _tableStopped;

    float _dryVolume;
    float _wetVolume;

    float _tempLeftPtr[SCRATCH_PIPELINE_MAX_BLOCK_FRAMES];
    float _tempRightPtr[SCRATCH_PIPELINE_MAX_BLOCK_FRAMES];
}

- (instancetype)initWithSampleRate:(double)sampleRate {
    self = [super init];
    if (self) {
        _speedRate = 1.0;
        _dryVolume = 0.0;
        _wetVolume = 1.0;
        _tableStopped = NO;
        _miniFaderIn = [[MiniFaderIn alloc] init];
        [self reconfigureWithSampleRate:sampleRate];
    }
    return self;
}

- (void)reconfigureWithSampleRate:(double)sampleRate {
    _sampleRate = sampleRate;
    _ring = [[RingBuffer alloc] initWithSampleRate:sampleRate];
}

- (double)sampleRate {
    return _sampleRate;
}

- (RingBuffer *)ring {
    return _ring;
}

- (double)speedRate {
    return _speedRate;
}

- (BOOL)tableStopped {
    return _tableStopped;
}

#pragma mark - AudioInputConsumer

- (void)audioInputProvidedFrames:(UInt32)frames
                            left:(const float *)left
                           right:(const float *)right {
    if (frames == 0) {
        return;
    }
    float *dstL = [_ring writePtrLeft];
    float *dstR = [_ring writePtrRight];
    memcpy(dstL, left, sizeof(float) * frames);
    memcpy(dstR, right, sizeof(float) * frames);
    [_ring advanceWritePtrSample:frames];
}

#pragma mark - AudioOutputRenderer

- (void)audioOutputNeedsFrames:(UInt32)inNumberFrames
                          left:(float *)pLeft
                         right:(float *)pRight {

    if (inNumberFrames > SCRATCH_PIPELINE_MAX_BLOCK_FRAMES) {
        // Never expected in practice; keep output defined by emitting silence.
        bzero(pLeft, sizeof(float) * inNumberFrames);
        bzero(pRight, sizeof(float) * inNumberFrames);
        return;
    }

    if ([_ring isShortage]) {
        bzero(pLeft, sizeof(float) * inNumberFrames);
        bzero(pRight, sizeof(float) * inNumberFrames);
        return;
    }

    if (![_ring dryPtrLeft] || ![_ring dryPtrRight]) {
        bzero(pLeft, sizeof(float) * inNumberFrames);
        bzero(pRight, sizeof(float) * inNumberFrames);
        return;
    }

    if (_speedRate == 1.0) {
        memcpy(pLeft, [_ring dryPtrLeft], sizeof(float) * inNumberFrames);
        memcpy(pRight, [_ring readPtrRight], sizeof(float) * inNumberFrames);
        [_ring advanceDryPtrSample:inNumberFrames];
        [_ring advanceReadPtrSample:inNumberFrames];

        [_miniFaderIn processLeft:pLeft right:pRight samples:inNumberFrames];
        return;
    }

    // dry
    {
        float *pSrcLeft = [_ring dryPtrLeft];
        float *pSrcRight = [_ring dryPtrRight];
        for (UInt32 i = 0; i < inNumberFrames; i++) {
            pLeft[i] = pSrcLeft[i] * _dryVolume;
            pRight[i] = pSrcRight[i] * _dryVolume;
        }
        [_ring advanceDryPtrSample:inNumberFrames];
    }

    // wet
    {
        SInt32 consumed = 0;
        [self convertAtRateFromLeft:[_ring readPtrLeft] right:[_ring readPtrRight]
                          ToSamples:inNumberFrames rate:_speedRate consumedFrames:&consumed];

        for (UInt32 i = 0; i < inNumberFrames; i++) {
            pLeft[i] += _tempLeftPtr[i] * _wetVolume;
            pRight[i] += _tempRightPtr[i] * _wetVolume;
        }

        [_ring advanceReadPtrSample:consumed];
    }
}

static double linearInterporation(int x0, double y0, int x1, double y1, double x) {
    if (x0 == x1) {
        return y0;
    }
    double rate = (x - x0) / (x1 - x0);
    double y = (1.0 - rate) * y0 + rate * y1;
    return y;
}

- (void)convertAtRateFromLeft:(float *)leftPtr right:(float *)rightPtr
                    ToSamples:(UInt32)inNumberFrames rate:(double)rate
               consumedFrames:(SInt32 *)consumed {
    *consumed = 0;

    for (UInt32 targetSample = 0; targetSample < inNumberFrames; targetSample++) {
        int x0 = floor(targetSample * rate);
        int x1 = ceil(targetSample * rate);

        float y0_l = leftPtr[x0];
        float y1_l = leftPtr[x1];
        float y_l = linearInterporation(x0, y0_l, x1, y1_l, targetSample * rate);

        float y0_r = rightPtr[x0];
        float y1_r = rightPtr[x1];
        float y_r = linearInterporation(x0, y0_r, x1, y1_r, targetSample * rate);

        _tempLeftPtr[targetSample] = y_l;
        _tempRightPtr[targetSample] = y_r;
        *consumed = x1;
    }
}

#pragma mark - Playback control

- (void)startPlayback {
    _tableStopped = NO;
    _speedRate = 1.0;
    [_miniFaderIn startFadeIn];
    [_ring follow];
}

- (void)beginStop {
    // Deceleration steps are driven externally via tickDeceleration.
}

- (BOOL)tickDeceleration {
    if (_speedRate < 0.01f) {
        _speedRate = 0.0f;
        _tableStopped = YES;
        return YES;
    }
    _speedRate -= 0.02;
    return NO;
}

- (void)setDryVolume:(float)dryVolume {
    _dryVolume = dryVolume;
}

- (BOOL)applyScratchSpeedRate:(double)rate isScratching:(BOOL)isScratching {
    _speedRate = rate;
    if (_speedRate == 0.0 && !isScratching && !_tableStopped) {
        _speedRate = 1.0;
        [_miniFaderIn startFadeIn];
        [_ring follow];
        return YES;
    }
    return NO;
}

@end
