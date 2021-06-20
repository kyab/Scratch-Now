//
//  AudioEngine.h
//  MyPlaythrough
//
//  Created by kyab on 2017/05/15.
//  Copyright © 2017年 kyab. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

@protocol AudioEngineDelegate <NSObject>
@optional
- (OSStatus) outCallback:(AudioUnitRenderActionFlags *)ioActionFlags inTimeStamp:(const AudioTimeStamp *) inTimeStamp inBusNumber:(UInt32) inBusNumber inNumberFrames:(UInt32)inNumberFrames ioData:(AudioBufferList *)ioData;

- (OSStatus) inCallback:(AudioUnitRenderActionFlags *)ioActionFlags inTimeStamp:(const AudioTimeStamp *) inTimeStamp inBusNumber:(UInt32) inBusNumber inNumberFrames:(UInt32)inNumberFrames ioData:(AudioBufferList *)ioData;

@end

@interface AudioEngine : NSObject{
    AUGraph _graph;
    AudioUnit _outUnit;
    AudioUnit _converterUnit;
    
    AudioUnit _inputUnit;
    
    BOOL _bIsPlaying;
    BOOL _bIsRecording;
    
    id<AudioEngineDelegate> _delegate;
    
    AudioDeviceID _preOutputDeviceID;

    
}

-(void)setRenderDelegate:(id<AudioEngineDelegate>)delegate;
-(BOOL)initialize;
-(BOOL)startOutput;
-(BOOL)stopOutput;
-(BOOL)startInput;
-(BOOL)stopInput;
-(BOOL)isPlaying;
-(BOOL)isRecording;

//system output
-(BOOL)changeSystemOutputDeviceToBGM;
-(BOOL)restoreSystemOutputDevice;


//-(BOOL)testAirPlay;

-(NSArray *)listDevices:(BOOL)output;
-(BOOL)changeInputDeviceTo:(NSString *)devName;

//called from delegate callback
- (OSStatus) readFromInput:(AudioUnitRenderActionFlags *)ioActionFlags inTimeStamp:(const AudioTimeStamp *) inTimeStamp inBusNumber:(UInt32) inBusNumber inNumberFrames:(UInt32)inNumberFrames ioData:(AudioBufferList *)ioData;
    

@end
