//
//  CaptureOutputSink.m
//  Scratch NowTests
//

#import "CaptureOutputSink.h"

#define CAPTURE_MAX_BLOCK_FRAMES 8192

@implementation CaptureOutputSink {
    double _sampleRate;
    NSMutableData *_leftData;
    NSMutableData *_rightData;
    NSUInteger _frameCount;
    float _blockLeft[CAPTURE_MAX_BLOCK_FRAMES];
    float _blockRight[CAPTURE_MAX_BLOCK_FRAMES];
}

@synthesize outputRenderer = _outputRenderer;

- (instancetype)initWithSampleRate:(double)sampleRate {
    self = [super init];
    if (self) {
        _sampleRate = sampleRate;
        _leftData = [NSMutableData data];
        _rightData = [NSMutableData data];
        _frameCount = 0;
    }
    return self;
}

- (double)sampleRate {
    return _sampleRate;
}

- (BOOL)startPlayback {
    return YES;
}

- (BOOL)stopPlayback {
    return YES;
}

- (void)pullFrames:(UInt32)frames {
    if (frames > CAPTURE_MAX_BLOCK_FRAMES) {
        frames = CAPTURE_MAX_BLOCK_FRAMES;
    }

    bzero(_blockLeft, sizeof(float) * frames);
    bzero(_blockRight, sizeof(float) * frames);

    [self.outputRenderer audioOutputNeedsFrames:frames left:_blockLeft right:_blockRight];

    [_leftData appendBytes:_blockLeft length:sizeof(float) * frames];
    [_rightData appendBytes:_blockRight length:sizeof(float) * frames];
    _frameCount += frames;
}

- (NSUInteger)frameCount {
    return _frameCount;
}

- (const float *)leftChannel {
    return (const float *)_leftData.bytes;
}

- (const float *)rightChannel {
    return (const float *)_rightData.bytes;
}

@end
