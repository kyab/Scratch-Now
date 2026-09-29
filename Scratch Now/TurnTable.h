//
//  TurnTable.h
//  Scratch Now
//

#import <Foundation/Foundation.h>
#import "RingBuffer.h"
#include <stdatomic.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    uint64_t hostTime;
    double speedStart;
    double speedEnd;
    UInt32 numSamples;
} SpeedLogRecord;

@interface TurnTable : NSObject{
    RingBuffer *_ring;

    // Platter input: written on the main thread, read by the audio thread.
    Boolean _isScratchingByPlatter;
    Boolean _isCoasting;
    double _platterSpeedRate;

    NSTimer *_coastTimer;
    double _coastTargetSpeed;
    NSTimeInterval _prevCoastSec;

    NSTimer *_tableStopTimer;
    Boolean _tableStopped;
    // Stop deceleration target; continues even while scratch temporarily owns _speedRate.
    double _tableStopSpeed;
    double _speedRate;
    Boolean _autoFollow;

    float _dryVolume;
    float _wetVolume;

    float _tempLeftPtr[1024];
    float _tempRightPtr[1024];

    // Scratch processing state.
    Boolean _isScratchStarting;
    Boolean _isReturningToLive;
    Boolean _isFadingOut;
    Boolean _isFadingIn;
    UInt32 _fadeOutCounter;
    UInt32 _fadeInCounter;
    double _smoothedSpeed;
    double _subSamplePos;
    double _wetGain;
    float _dcPrevInL;
    float _dcPrevOutL;
    float _dcPrevInR;
    float _dcPrevOutR;
    Boolean _isScratching;

    // Tuning log (enabled by SCRATCH_SPEED_LOG=1): single-producer (audio thread),
    // single-consumer (main thread) ring of preallocated records.
    SpeedLogRecord *_speedLog;
    UInt32 _speedLogCapacity;
    _Atomic uint64_t _speedLogWriteCount;
    _Atomic uint64_t _speedLogReadCount;
    _Atomic uint64_t _speedLogDroppedCount;
    uint64_t _speedLogReportedDroppedCount;
    uint64_t _speedLogBaseHostTime;
    NSTimeInterval _speedLogBaseEpochSec;
    double _speedLogSecPerHostTick;
    NSTimer *_speedLogTimer;
}

-(instancetype)initWithSampleRate:(double)sampleRate;
// Called after the audio engine has stopped its callbacks.
-(void)rebuildWithSampleRate:(double)sampleRate;
-(RingBuffer *)ring;

// Audio thread
-(void)processInputLeft:(const float *)leftBuf right:(const float *)rightBuf frames:(UInt32)numFrames;
-(void)processOutputLeft:(float *)leftBuf right:(float *)rightBuf frames:(UInt32)numFrames;

// Main thread
-(void)start;
-(void)stop;
-(void)follow;
-(void)setAutoFollow:(Boolean)autoFollow;
-(void)setDryVolume:(float)dryVolume;

// Main thread. speedRate is normalized so that 1.0 is 33.3 rpm forward.
-(void)beginScratch;
-(void)updateScratchSpeed:(double)speedRate;
-(void)endScratchWithReleaseSpeed:(double)speedRate;

@end

NS_ASSUME_NONNULL_END
