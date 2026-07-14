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

@protocol AudioEngineDelegate <NSObject>
@optional
- (OSStatus) outCallback:(AudioUnitRenderActionFlags *)ioActionFlags inTimeStamp:(const AudioTimeStamp *) inTimeStamp inBusNumber:(UInt32) inBusNumber inNumberFrames:(UInt32)inNumberFrames ioData:(AudioBufferList *)ioData;

- (OSStatus) inCallback:(AudioUnitRenderActionFlags *)ioActionFlags inTimeStamp:(const AudioTimeStamp *) inTimeStamp inBusNumber:(UInt32) inBusNumber inNumberFrames:(UInt32)inNumberFrames ioData:(AudioBufferList *)ioData;

- (void)audioEngine:(id)engine didReconfigureToSampleRate:(double)sampleRate;

@end

@interface AudioEngine : NSObject{
    AUGraph _graph;
    AudioUnit _outUnit;
    AudioUnit _converterUnit;
    
    // CATap capture path (replaces the former HAL input unit)
    AudioObjectID _tapID;
    AudioObjectID _aggregateID;
    AudioDeviceIOProcID _ioProcID;
    AudioStreamBasicDescription _tapASBD;
    double _engineSampleRate;
    
    // Valid only while the tap IOProc is invoking the delegate
    const AudioBufferList *_currentTapBufferList;
    UInt32 _currentTapFrames;
    
    BOOL _bIsPlaying;
    BOOL _bIsRecording;
    
    id<AudioEngineDelegate> _delegate;
    
    AudioDeviceID _outputDeviceID;

    dispatch_queue_t _diagnosticsQueue;
    AudioObjectPropertyListenerBlock _diagnosticDefaultOutputListener;
    BOOL _diagnosticDefaultOutputListenerRegistered;
    BOOL _isReconfiguring;
    BOOL _isTerminating;
    
}

-(void)setRenderDelegate:(id<AudioEngineDelegate>)delegate;
-(BOOL)initialize;
-(BOOL)startOutput;
-(BOOL)stopOutput;
-(BOOL)startInput;
-(BOOL)stopInput;
-(void)teardownInput;
-(void)shutdown;
-(BOOL)isPlaying;
-(BOOL)isRecording;

// Sample rate the whole pipeline runs at (taken from the device-specific tap format)
-(double)sampleRate;

//called from delegate callback
- (OSStatus) readFromInput:(AudioUnitRenderActionFlags *)ioActionFlags inTimeStamp:(const AudioTimeStamp *) inTimeStamp inBusNumber:(UInt32) inBusNumber inNumberFrames:(UInt32)inNumberFrames ioData:(AudioBufferList *)ioData;
    

@end
