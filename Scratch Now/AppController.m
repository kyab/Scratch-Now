//
//  AppController.m
//  Scratch Now
//
//  Created by kyab on 2021/06/19.
//

#import "AppController.h"

@implementation AppController

-(void)awakeFromNib{
    _ring = [[RingBuffer alloc] init];
    [_turnTableView setRingBuffer:_ring];
    
    [_turnTableView setDelegate:(id<TurnTableDelegate>)self];
    [_turnTableView start];
    _speedRate = 1.0;
    
    _dryVolume = 0.0;
    _wetVolume = 1.0;
    
    _miniFaderIn = [[MiniFaderIn alloc] init];
    
    
    _ae = [[AudioEngine alloc] init];
    if([_ae initialize]){
        NSLog(@"AudioEngine all OK");
    }
    [_ae setRenderDelegate:(id<AudioEngineDelegate>)self];
    
    [_ae changeSystemOutputDeviceToBGM];
//    [_ae startInput];
    [_ae startOutput];
    [_ae startInput];
    
    
}

- (OSStatus) inCallback:(AudioUnitRenderActionFlags *)ioActionFlags inTimeStamp:(const AudioTimeStamp *) inTimeStamp inBusNumber:(UInt32) inBusNumber inNumberFrames:(UInt32)inNumberFrames ioData:(AudioBufferList *)ioData{
    

    static BOOL printNumFrames = NO;
    if (!printNumFrames){
        NSLog(@"inCallback NumFrames = %d", inNumberFrames);
        printNumFrames = YES;
    }
    
    AudioBufferList *bufferList = (AudioBufferList *)malloc(sizeof(AudioBufferList) +  sizeof(AudioBuffer)); // for 2 buffers for left and right
    
    float *leftPrt = [_ring writePtrLeft];
    float *rightPtr = [_ring writePtrRight];
    
    bufferList->mNumberBuffers = 2;
    bufferList->mBuffers[0].mDataByteSize = 32*inNumberFrames;
    bufferList->mBuffers[0].mNumberChannels = 1;
    bufferList->mBuffers[0].mData = leftPrt;
    bufferList->mBuffers[1].mDataByteSize = 32*inNumberFrames;
    bufferList->mBuffers[1].mNumberChannels = 1;
    bufferList->mBuffers[1].mData = rightPtr;
    
    
    OSStatus ret = [_ae readFromInput:ioActionFlags inTimeStamp:inTimeStamp inBusNumber:inBusNumber inNumberFrames:inNumberFrames ioData:bufferList];
    
    
    free(bufferList);
    
    if ([_ae isRecording]){
        [_ring advanceWritePtrSample:inNumberFrames];
    }
    
    return ret;
    
}

- (OSStatus) outCallback:(AudioUnitRenderActionFlags *)ioActionFlags inTimeStamp:(const AudioTimeStamp *) inTimeStamp inBusNumber:(UInt32) inBusNumber inNumberFrames:(UInt32)inNumberFrames ioData:(AudioBufferList *)ioData{
    
    static BOOL printedNumFrames = NO;
    if (!printedNumFrames){
        NSLog(@"outCallback NumFrames = %d", inNumberFrames);
        printedNumFrames = YES;
    }

    if (![_ae isPlaying]){
        UInt32 sampleNum = inNumberFrames;
        float *pLeft = (float *)ioData->mBuffers[0].mData;
        float *pRight = (float *)ioData->mBuffers[1].mData;
        bzero(pLeft,sizeof(float)*sampleNum );
        bzero(pRight,sizeof(float)*sampleNum );
        NSLog(@"ae not playing");
        return noErr;
    }
    
    if ([_ring isShortage]){
        UInt32 sampleNum = inNumberFrames;
        float *pLeft = (float *)ioData->mBuffers[0].mData;
        float *pRight = (float *)ioData->mBuffers[1].mData;
        bzero(pLeft,sizeof(float)*sampleNum );
        bzero(pRight,sizeof(float)*sampleNum );
//        NSLog(@"shortage in out thread");
        return noErr;
    }
    
    if (![_ring dryPtrLeft] || ![_ring dryPtrRight]){
         //not enough buffer
        NSLog(@"no enough buffer on read");
        UInt32 sampleNum = inNumberFrames;
        float *pLeft = (float *)ioData->mBuffers[0].mData;
        float *pRight = (float *)ioData->mBuffers[1].mData;
        bzero(pLeft, sizeof(float)*sampleNum );
        bzero(pRight, sizeof(float)*sampleNum );
        return noErr;
     }
    
    if(_speedRate == 1.0){
        
        float *dstL = ioData->mBuffers[0].mData;
        float *dstR = ioData->mBuffers[1].mData;
        memcpy(dstL, [_ring dryPtrLeft], sizeof(float) * inNumberFrames);
        memcpy(dstR, [_ring readPtrRight], sizeof(float) * inNumberFrames);
        [_ring advanceDryPtrSample:inNumberFrames];
        [_ring advanceReadPtrSample:inNumberFrames];
        
        [_miniFaderIn processLeft:dstL right:dstR samples:inNumberFrames];
        
        return noErr;
    }
    
    //dry
    {
        float *pSrcLeft = [_ring dryPtrLeft];
        float *pSrcRight = [_ring dryPtrRight];
        float *pDstLeft = (float *)ioData->mBuffers[0].mData;
        float *pDstRight = (float *)ioData->mBuffers[1].mData;
        
        for(int i = 0; i < inNumberFrames; i++){
            pDstLeft[i]  = pSrcLeft[i] * _dryVolume;
            pDstRight[i] = pSrcRight[i] * _dryVolume;
        }
        [_ring advanceDryPtrSample:inNumberFrames];
    }
    
    //wet
    {
        SInt32 consumed = 0;
        [self convertAtRateFromLeft:[_ring readPtrLeft] right:[_ring readPtrRight] ToSamples:inNumberFrames
                               rate:_speedRate consumedFrames:&consumed];

        float *pDstLeft = (float *)ioData->mBuffers[0].mData;
        float *pDstRight = (float *)ioData->mBuffers[1].mData;
        
        for(int i = 0; i < inNumberFrames; i++){
            pDstLeft[i] += _tempLeftPtr[i] * _wetVolume;
            pDstRight[i] += _tempRightPtr[i] * _wetVolume;
        }

        [_ring advanceReadPtrSample:consumed];
    }
    
    return noErr;

    
}

static double linearInterporation(int x0, double y0, int x1, double y1, double x){
    if (x0 == x1){
        return y0;
    }
    double rate = (x - x0) / (x1 - x0);
    double y = (1.0 - rate)*y0 + rate*y1;
    return y;
}

-(void)convertAtRateFromLeft:(float *)leftPtr right:(float *)rightPtr ToSamples:(UInt32)inNumberFrames rate:(double)rate consumedFrames:(SInt32 *)consumed{
    if (rate == 1.0 || rate==0.0 || rate ==-0.0){
        [self convertAtRatePlusFromLeft:leftPtr right:rightPtr ToSamples:inNumberFrames rate:rate consumedFrames:consumed];
    }else{
        [self convertAtRatePlusFromLeft:leftPtr right:rightPtr ToSamples:inNumberFrames rate:rate consumedFrames:consumed];
    }
}

-(void)convertAtRatePlusFromLeft:(float *)leftPtr right:(float *)rightPtr ToSamples:(UInt32)inNumberFrames rate:(double)rate consumedFrames:(SInt32 *)consumed{
    
    *consumed = 0;
    
    for (int targetSample = 0; targetSample < inNumberFrames; targetSample++){
        int x0 = floor(targetSample*rate);
        int x1 = ceil(targetSample*rate);
        
        float y0_l = leftPtr[x0];
        float y1_l = leftPtr[x1];
        float y_l = linearInterporation(x0, y0_l, x1, y1_l, targetSample*rate);
        
        float y0_r = rightPtr[x0];
        float y1_r = rightPtr[x1];
        float y_r = linearInterporation(x0, y0_r, x1, y1_r, targetSample*rate);
        
        _tempLeftPtr[targetSample] = y_l;
        _tempRightPtr[targetSample] = y_r;
        *consumed = x1;
    }
    
}

- (IBAction)dryVolumeChanged:(id)sender {
    _dryVolume = _sliderDry.floatValue;
}

- (IBAction)startStopButtonClicked:(id)sender {
    if (_btnStop.state == NSControlStateValueOn){
        if (_tableStopTimer){
            [_tableStopTimer invalidate];
        }
        
        _tableStopped = NO;
        _speedRate = 1.0;
        [_miniFaderIn startFadeIn];
        [_ring follow];
        
        [_btnStop setTitle:@"[S]top"];
    }else{
        _tableStopTimer = [NSTimer scheduledTimerWithTimeInterval:0.01 target:self selector:@selector(tableStopTimer:) userInfo:nil repeats:YES];
        [_btnStop setTitle:@"[S]tart"];
    }
}



- (void)tableStopTimer:(NSTimer *)t {
    if (_speedRate < 0.01f){
        _speedRate = 0.0f;
        [_tableStopTimer invalidate];
        _tableStopped = YES;
    }else{
        _speedRate -= 0.02;
    }
}

-(void)turnTableSpeedRateChanged{
    _speedRate = [_turnTableView speedRate];
    if (_speedRate == 0.0 && ![_turnTableView isScratching] && !_tableStopped){
        _speedRate = 1.0;
        [_turnTableView setSpeedRate:_speedRate];
        [_miniFaderIn startFadeIn];
        [_ring follow];
    }
}


-(void)terminate{
    [_ae stopOutput];
    [_ae stopInput];
    [_ae restoreSystemOutputDevice];
}
@end
