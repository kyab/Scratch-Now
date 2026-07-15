//
//  ScratchPipeline.h
//  Scratch Now
//
//  Real-time DSP core extracted from AppController. Owns the ring buffer and the
//  turntable playback state (speed rate, stop deceleration, dry/wet mix, fade in)
//  so the exact same processing can run under real Core Audio I/O or offline tests.
//

#import <Foundation/Foundation.h>
#import "AudioPipelineProtocols.h"
#import "RingBuffer.h"
#import "MiniFader.h"

NS_ASSUME_NONNULL_BEGIN

@interface ScratchPipeline : NSObject <AudioInputConsumer, AudioOutputRenderer>

- (instancetype)initWithSampleRate:(double)sampleRate;

// Rebuild the ring buffer for a new sample rate (e.g. after an output device change).
- (void)reconfigureWithSampleRate:(double)sampleRate;

@property (nonatomic, readonly) double sampleRate;

// The backing ring buffer (shared with the turntable view for visualization).
@property (nonatomic, readonly) RingBuffer *ring;

// --- Playback control (driven by the Start/Stop button, scratch, dry slider) ---

// Start/resume normal playback (Start button ON): reset stop state, speed 1.0,
// fade in and re-follow the write head.
- (void)startPlayback;

// Begin the turntable stop deceleration (Start button OFF).
- (void)beginStop;

// One deceleration step. Production calls this on a 10ms timer; tests call it on a
// virtual 10ms cadence. Returns YES once the platter has fully stopped.
- (BOOL)tickDeceleration;

- (void)setDryVolume:(float)dryVolume;

// Apply a scratch speed rate coming from the turntable. Returns YES if playback
// auto-resumed to 1.0 (so the caller can sync the turntable UI back to 1.0).
- (BOOL)applyScratchSpeedRate:(double)rate isScratching:(BOOL)isScratching;

@property (nonatomic, readonly) double speedRate;
@property (nonatomic, readonly) BOOL tableStopped;

@end

NS_ASSUME_NONNULL_END
