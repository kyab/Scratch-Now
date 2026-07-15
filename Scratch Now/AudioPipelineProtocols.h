//
//  AudioPipelineProtocols.h
//  Scratch Now
//
//  Abstraction seams that let the same DSP pipeline run against either the real
//  Core Audio I/O (CATap capture + HAL output) or synthetic test doubles.
//
//  Data model across the whole pipeline: non-interleaved 32-bit float, stereo
//  (separate left/right buffers), running at a single sample rate decided by the
//  input source.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Receives captured input frames pushed by an AudioInputSource.
@protocol AudioInputConsumer <NSObject>
- (void)audioInputProvidedFrames:(UInt32)frames
                            left:(const float *)left
                           right:(const float *)right;
@end

// Produces processed output frames pulled by an AudioOutputSink.
@protocol AudioOutputRenderer <NSObject>
- (void)audioOutputNeedsFrames:(UInt32)frames
                          left:(float *)left
                         right:(float *)right;
@end

// A source of input audio. Production: CATap capture. Test: synthetic generator.
@protocol AudioInputSource <NSObject>
@property (nonatomic, weak, nullable) id<AudioInputConsumer> inputConsumer;
- (double)sampleRate;
- (BOOL)startCapture;
- (BOOL)stopCapture;
@end

// A destination for output audio. Production: HAL output. Test: memory capture.
@protocol AudioOutputSink <NSObject>
@property (nonatomic, weak, nullable) id<AudioOutputRenderer> outputRenderer;
- (double)sampleRate;
- (BOOL)startPlayback;
- (BOOL)stopPlayback;
@end

NS_ASSUME_NONNULL_END
