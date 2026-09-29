//
//  AppController.m
//  Scratch Now
//
//  Created by kyab on 2021/06/19.
//

#import "AppController.h"

@implementation AppController

-(void)awakeFromNib{
    //Initialize the engine first: the device-specific tap decides the pipeline sample rate,
    //which the ring buffer allocation depends on.
    _ae = [[AudioEngine alloc] init];
    [_ae setRenderDelegate:(id<AudioEngineDelegate>)self];
    if([_ae initialize]){
        NSLog(@"AudioEngine all OK");
    }

    _turnTable = [[TurnTable alloc] initWithSampleRate:[_ae sampleRate]];

    _turnTableController = [[TurnTableController alloc] initWithNibName:@"TurnTableController" bundle:nil];
    NSView *turnTableView = [_turnTableController view];
    [turnTableView setFrame:[_turnTableContentView bounds]];
    [turnTableView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [_turnTableContentView addSubview:turnTableView];
    [_turnTableController setTurnTable:_turnTable];

    [_ae startOutput];
    [_ae startInput];
}

- (OSStatus) inCallback:(AudioUnitRenderActionFlags *)ioActionFlags inTimeStamp:(const AudioTimeStamp *) inTimeStamp inBusNumber:(UInt32) inBusNumber inNumberFrames:(UInt32)inNumberFrames ioData:(AudioBufferList *)ioData{
    static BOOL printNumFrames = NO;
    if (!printNumFrames){
        NSLog(@"inCallback NumFrames = %d", inNumberFrames);
        printNumFrames = YES;
    }

    UInt32 frames = inNumberFrames;
    if (frames > INPUT_BUFFER_FRAMES){
        frames = INPUT_BUFFER_FRAMES;
    }

    struct {
        UInt32 mNumberBuffers;
        AudioBuffer mBuffers[2];
    } stereoBufferList;
    stereoBufferList.mNumberBuffers = 2;
    stereoBufferList.mBuffers[0].mNumberChannels = 1;
    stereoBufferList.mBuffers[0].mDataByteSize = (UInt32)sizeof(float) * frames;
    stereoBufferList.mBuffers[0].mData = _inputLeft;
    stereoBufferList.mBuffers[1].mNumberChannels = 1;
    stereoBufferList.mBuffers[1].mDataByteSize = (UInt32)sizeof(float) * frames;
    stereoBufferList.mBuffers[1].mData = _inputRight;

    OSStatus ret = [_ae readFromInput:ioActionFlags inTimeStamp:inTimeStamp inBusNumber:inBusNumber inNumberFrames:frames ioData:(AudioBufferList *)&stereoBufferList];

    if ([_ae isRecording]){
        [_turnTable processInputLeft:_inputLeft right:_inputRight frames:frames];
    }

    return ret;
}

- (OSStatus) outCallback:(AudioUnitRenderActionFlags *)ioActionFlags inTimeStamp:(const AudioTimeStamp *) inTimeStamp inBusNumber:(UInt32) inBusNumber inNumberFrames:(UInt32)inNumberFrames ioData:(AudioBufferList *)ioData{
    static BOOL printedNumFrames = NO;
    if (!printedNumFrames){
        NSLog(@"outCallback NumFrames = %d", inNumberFrames);
        printedNumFrames = YES;
    }

    float *dstL = (float *)ioData->mBuffers[0].mData;
    float *dstR = (float *)ioData->mBuffers[1].mData;

    if (![_ae isPlaying]){
        bzero(dstL, sizeof(float) * inNumberFrames);
        bzero(dstR, sizeof(float) * inNumberFrames);
        NSLog(@"ae not playing");
        return noErr;
    }

    [_turnTable processOutputLeft:dstL right:dstR frames:inNumberFrames];
    return noErr;
}

// The engine has stopped its audio callbacks before this notification.
- (void)audioEngineDidRebuildPipeline:(AudioEngine *)engine{
    [_turnTable rebuildWithSampleRate:[engine sampleRate]];
}

-(void)terminate{
    [_ae shutdown];
}
@end
