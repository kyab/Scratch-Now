//
//  CaptureOutputSink.h
//  Scratch NowTests
//
//  Test double for AudioOutputSink. Instead of playing to hardware, it pulls
//  processed frames from the pipeline and accumulates them in memory for analysis.
//

#import <Foundation/Foundation.h>
#import "AudioPipelineProtocols.h"

NS_ASSUME_NONNULL_BEGIN

@interface CaptureOutputSink : NSObject <AudioOutputSink>

- (instancetype)initWithSampleRate:(double)sampleRate;

// Pull `frames` from the output renderer and append them to the capture buffers.
- (void)pullFrames:(UInt32)frames;

// Number of frames captured so far.
@property (nonatomic, readonly) NSUInteger frameCount;

// Captured non-interleaved channels. Valid for indices [0, frameCount).
- (const float *)leftChannel;
- (const float *)rightChannel;

@end

NS_ASSUME_NONNULL_END
