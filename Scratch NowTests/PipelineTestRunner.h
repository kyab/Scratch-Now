//
//  PipelineTestRunner.h
//  Scratch NowTests
//
//  Offline driver that runs the real ScratchPipeline against synthetic input and a
//  capture output sink using a virtual sample clock (no real time, no Core Audio).
//
//  Scenarios are expressed as control events scheduled on a virtual timeline, so new
//  test variations (dry mix, scratch, resume, ...) reuse the same harness.
//

#import <Foundation/Foundation.h>
#import "ScratchPipeline.h"
#import "SyntheticInputSource.h"
#import "CaptureOutputSink.h"

NS_ASSUME_NONNULL_BEGIN

@interface PipelineTestRunner : NSObject

- (instancetype)initWithSampleRate:(double)sampleRate blockFrames:(UInt32)blockFrames;

@property (nonatomic, readonly) ScratchPipeline *pipeline;
@property (nonatomic, readonly) SyntheticInputSource *input;
@property (nonatomic, readonly) CaptureOutputSink *output;
@property (nonatomic, readonly) double sampleRate;

// Schedule an arbitrary control action (dry volume, scratch, tone change, ...) at a
// virtual time measured in seconds from the start of the captured run.
- (void)scheduleAtSeconds:(double)seconds action:(void (^)(PipelineTestRunner *runner))action;

// Schedule the Start/Stop button OFF (turntable stop). The runner then fires the
// 10ms deceleration ticks deterministically until the platter stops.
- (void)scheduleStopAtSeconds:(double)seconds;

// Prime the ring with input, engage playback, then capture output for `seconds`.
- (void)runForSeconds:(double)seconds;

@end

NS_ASSUME_NONNULL_END
