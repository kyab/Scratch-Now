//
//  SyntheticInputSource.h
//  Scratch NowTests
//
//  Test double for AudioInputSource. Generates a deterministic stereo tone (or
//  silence) and pushes it to the pipeline, replacing the real CATap capture.
//

#import <Foundation/Foundation.h>
#import "AudioPipelineProtocols.h"

NS_ASSUME_NONNULL_BEGIN

@interface SyntheticInputSource : NSObject <AudioInputSource>

- (instancetype)initWithSampleRate:(double)sampleRate;

// Tone parameters. A frequency of 0 (or amplitude 0) produces silence.
@property (nonatomic) double frequency;
@property (nonatomic) double amplitude;

// Generate `frames` of the current tone and push them to the input consumer.
- (void)produceFrames:(UInt32)frames;

@end

NS_ASSUME_NONNULL_END
