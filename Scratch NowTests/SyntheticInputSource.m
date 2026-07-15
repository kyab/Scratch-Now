//
//  SyntheticInputSource.m
//  Scratch NowTests
//

#import "SyntheticInputSource.h"
#import <math.h>

#define SYNTH_MAX_BLOCK_FRAMES 8192

@implementation SyntheticInputSource {
    double _sampleRate;
    double _phase;
    float _blockLeft[SYNTH_MAX_BLOCK_FRAMES];
    float _blockRight[SYNTH_MAX_BLOCK_FRAMES];
}

@synthesize inputConsumer = _inputConsumer;

- (instancetype)initWithSampleRate:(double)sampleRate {
    self = [super init];
    if (self) {
        _sampleRate = sampleRate;
        _phase = 0.0;
        _frequency = 0.0;
        _amplitude = 0.0;
    }
    return self;
}

- (double)sampleRate {
    return _sampleRate;
}

- (BOOL)startCapture {
    return YES;
}

- (BOOL)stopCapture {
    return YES;
}

- (void)produceFrames:(UInt32)frames {
    if (frames > SYNTH_MAX_BLOCK_FRAMES) {
        frames = SYNTH_MAX_BLOCK_FRAMES;
    }

    double phaseIncrement = 2.0 * M_PI * _frequency / _sampleRate;
    for (UInt32 i = 0; i < frames; i++) {
        float sample = (float)(_amplitude * sin(_phase));
        _blockLeft[i] = sample;
        _blockRight[i] = sample;
        _phase += phaseIncrement;
        if (_phase >= 2.0 * M_PI) {
            _phase -= 2.0 * M_PI;
        }
    }

    [self.inputConsumer audioInputProvidedFrames:frames left:_blockLeft right:_blockRight];
}

@end
