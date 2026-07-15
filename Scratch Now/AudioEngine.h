//
//  AudioEngine.h
//  MyPlaythrough
//
//  Created by kyab on 2017/05/15.
//  Copyright © 2017年 kyab. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#import <dispatch/dispatch.h>
#import "AudioPipelineProtocols.h"

NS_ASSUME_NONNULL_BEGIN

@class AudioEngine;

// Notified after the capture/output pipeline was rebuilt (e.g. the default output
// device or its sample rate changed). The consumer/renderer should reconfigure any
// sample-rate dependent state (such as the ring buffer) at this point.
@protocol AudioEngineRebuildDelegate <NSObject>
- (void)audioEngineDidRebuildPipeline:(AudioEngine *)engine;
@end

// Production implementation of both audio abstractions: the CATap-based capture
// (AudioInputSource) and the HAL-based output (AudioOutputSink). Capture and output
// are one coupled unit here because the process tap is bound to the current output
// device; tests substitute independent synthetic input / capture output doubles.
@interface AudioEngine : NSObject <AudioInputSource, AudioOutputSink> {
    AUGraph _graph;
    AudioUnit _outUnit;
    AudioUnit _converterUnit;

    // CATap capture path (replaces the former HAL input unit)
    AudioObjectID _tapID;
    AudioObjectID _aggregateID;
    AudioDeviceIOProcID _ioProcID;
    AudioStreamBasicDescription _tapASBD;
    double _engineSampleRate;

    // Scratch buffers used to deinterleave interleaved tap captures before handing
    // non-interleaved L/R frames to the input consumer.
    float *_deinterleaveLeft;
    float *_deinterleaveRight;
    UInt32 _deinterleaveCapacityFrames;

    BOOL _bIsPlaying;
    BOOL _bIsRecording;

    AudioDeviceID _outputDeviceID;

    dispatch_queue_t _defaultOutputListenerQueue;
    AudioObjectPropertyListenerBlock _defaultOutputListener;
    AudioObjectPropertyListenerBlock _outputSampleRateListener;
    BOOL _defaultOutputListenerRegistered;
    BOOL _outputSampleRateListenerRegistered;
    BOOL _isReconfiguring;
    BOOL _isTerminating;
}

@property (nonatomic, weak, nullable) id<AudioInputConsumer> inputConsumer;
@property (nonatomic, weak, nullable) id<AudioOutputRenderer> outputRenderer;
@property (nonatomic, weak, nullable) id<AudioEngineRebuildDelegate> rebuildDelegate;

-(BOOL)initialize;
-(BOOL)startOutput;
-(BOOL)stopOutput;
-(BOOL)startInput;
-(BOOL)stopInput;
-(void)shutdown;
-(BOOL)isPlaying;
-(BOOL)isRecording;

// Sample rate the whole pipeline runs at (taken from the device-specific tap format)
-(double)sampleRate;

// AudioInputSource / AudioOutputSink protocol methods (thin aliases over the
// input/output start/stop calls above).
-(BOOL)startCapture;
-(BOOL)stopCapture;
-(BOOL)startPlayback;
-(BOOL)stopPlayback;

@end

NS_ASSUME_NONNULL_END
