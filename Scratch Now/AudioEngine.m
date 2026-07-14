//
//  AudioEngine.m
//  MyPlaythrough
//
//  Created by kyab on 2017/05/15.
//  Copyright © 2017年 kyab. All rights reserved.
//

#import "AudioEngine.h"
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <math.h>

#define AGGREGATE_DEVICE_UID @"com.kyab.Scratch-Now.tap-aggregate"
#define ENABLE_OUTPUT_SWITCH_DIAGNOSTICS 1

@interface AudioEngine ()
#if ENABLE_OUTPUT_SWITCH_DIAGNOSTICS
- (void)registerDefaultOutputDiagnostics;
- (void)unregisterDefaultOutputDiagnostics;
- (BOOL)readDefaultOutputDevice:(AudioDeviceID *)outputDeviceID;
- (void)logOutputDevice:(AudioDeviceID)deviceID context:(NSString *)context;
#endif
@end


@implementation AudioEngine
- (id)init
{
    self = [super init];
    _tapID = kAudioObjectUnknown;
    _aggregateID = kAudioObjectUnknown;
    _ioProcID = NULL;
    _diagnosticsQueue = dispatch_queue_create("com.kyab.ScratchNow.output-diagnostics",
                                              DISPATCH_QUEUE_SERIAL);
    return self;
}


-(void)setRenderDelegate:(id<AudioEngineDelegate>)delegate{
    _delegate = delegate;
}


OSStatus MyRender(void *inRefCon,
                  AudioUnitRenderActionFlags *ioActionFlags,
                  const AudioTimeStamp      *inTimeStamp,
                  UInt32 inBusNumber,
                  UInt32 inNumberFrames,
                  AudioBufferList *ioData){
    AudioEngine *engine = (__bridge AudioEngine *)inRefCon;
    return [engine renderOutput:ioActionFlags inTimeStamp:inTimeStamp inBusNumber:inBusNumber inNumberFrames:inNumberFrames ioData:ioData];
}

- (OSStatus) renderOutput:(AudioUnitRenderActionFlags *)ioActionFlags inTimeStamp:(const AudioTimeStamp *) inTimeStamp inBusNumber:(UInt32) inBusNumber inNumberFrames:(UInt32)inNumberFrames ioData:(AudioBufferList *)ioData{
    return [_delegate outCallback:ioActionFlags inTimeStamp:inTimeStamp inBusNumber:inBusNumber inNumberFrames:inNumberFrames ioData:ioData];
}

//IOProc attached to the private aggregate device. inInputData carries the tap capture.
static OSStatus TapIOProc(AudioObjectID inDevice,
                          const AudioTimeStamp *inNow,
                          const AudioBufferList *inInputData,
                          const AudioTimeStamp *inInputTime,
                          AudioBufferList *outOutputData,
                          const AudioTimeStamp *inOutputTime,
                          void *inClientData){
    AudioEngine *engine = (__bridge AudioEngine *)inClientData;
    return [engine handleTapInput:inInputData inTimeStamp:inInputTime];
}

- (OSStatus) handleTapInput:(const AudioBufferList *)inInputData inTimeStamp:(const AudioTimeStamp *)inTimeStamp{
    
    if (!inInputData || inInputData->mNumberBuffers == 0){
        return noErr;
    }
    
    const AudioBuffer *buf0 = &inInputData->mBuffers[0];
    UInt32 bytesPerFrame = buf0->mNumberChannels * sizeof(float);
    if (bytesPerFrame == 0){
        return noErr;
    }
    UInt32 frames = buf0->mDataByteSize / bytesPerFrame;
    if (frames == 0){
        return noErr;
    }
    
#if ENABLE_OUTPUT_SWITCH_DIAGNOSTICS
    // Temporary once-per-second capture proof for the hardware baseline.
    {
        static UInt32 frameCounter = 0;
        static float peak = 0.0f;
        const float *p = (const float *)buf0->mData;
        UInt32 n = buf0->mDataByteSize / sizeof(float);
        for (UInt32 i = 0; i < n; i++){
            float v = fabsf(p[i]);
            if (v > peak) peak = v;
        }
        frameCounter += frames;
        if (frameCounter >= (UInt32)_engineSampleRate){
            NSLog(@"Output diagnostics: tapCapture peak=%f framesPerCallback=%u buffers=%u channels=%u configuredOutput=%u",
                  peak, frames, inInputData->mNumberBuffers, buf0->mNumberChannels,
                  _outputDeviceID);
            frameCounter = 0;
            peak = 0.0f;
        }
    }
#endif
    
    //Bridge push-style IOProc to the existing pull-style delegate flow:
    //the delegate calls back readFromInput, which copies from _currentTapBufferList.
    _currentTapBufferList = inInputData;
    _currentTapFrames = frames;
    
    AudioUnitRenderActionFlags flags = 0;
    OSStatus ret = [_delegate inCallback:&flags inTimeStamp:inTimeStamp inBusNumber:1 inNumberFrames:frames ioData:NULL];
    
    _currentTapBufferList = NULL;
    _currentTapFrames = 0;
    
    return ret;
}


//actual read from input. should be called from delegate's inCallback
//copies the tap capture buffer into ioData (2 mono buffers, L/R)
- (OSStatus) readFromInput:(AudioUnitRenderActionFlags *)ioActionFlags inTimeStamp:(const AudioTimeStamp *) inTimeStamp inBusNumber:(UInt32) inBusNumber inNumberFrames:(UInt32)inNumberFrames ioData:(AudioBufferList *)ioData{

    if (!ioData || ioData->mNumberBuffers < 2){
        return kAudio_ParamError;
    }
    
    float *dstL = (float *)ioData->mBuffers[0].mData;
    float *dstR = (float *)ioData->mBuffers[1].mData;
    
    if (!_currentTapBufferList){
        NSLog(@"readFromInput called outside of tap IOProc");
        bzero(dstL, sizeof(float)*inNumberFrames);
        bzero(dstR, sizeof(float)*inNumberFrames);
        return noErr;
    }
    
    UInt32 frames = MIN(inNumberFrames, _currentTapFrames);
    const AudioBufferList *src = _currentTapBufferList;
    
    if (src->mNumberBuffers >= 2){
        //non-interleaved: buffer per channel
        memcpy(dstL, src->mBuffers[0].mData, sizeof(float)*frames);
        memcpy(dstR, src->mBuffers[1].mData, sizeof(float)*frames);
    }else if (src->mBuffers[0].mNumberChannels == 2){
        //interleaved stereo: deinterleave
        const float *p = (const float *)src->mBuffers[0].mData;
        for (UInt32 i = 0; i < frames; i++){
            dstL[i] = p[2*i];
            dstR[i] = p[2*i + 1];
        }
    }else{
        //mono: duplicate to both channels
        const float *p = (const float *)src->mBuffers[0].mData;
        memcpy(dstL, p, sizeof(float)*frames);
        memcpy(dstR, p, sizeof(float)*frames);
    }
    
    if (frames < inNumberFrames){
        bzero(dstL + frames, sizeof(float)*(inNumberFrames - frames));
        bzero(dstR + frames, sizeof(float)*(inNumberFrames - frames));
    }
    
    return noErr;
}



-(BOOL)initialize{
    if (![self obtainDefaultOutputDevice]){
        return NO;
    }
    
    // Create a tap bound to the current output device.
    if (![self createProcessTap]){
        return NO;
    }
    
    if (![self readTapFormat]){
        return NO;
    }
    
    if (![self initializeOutput]){
        return NO;
    }
    
    if (![self setupLowLatencyOutput]){
        return NO;
    }
    
    if (![self createAggregateDevice]){
        return NO;
    }
    
    if (![self createIOProc]){
        return NO;
    }

#if ENABLE_OUTPUT_SWITCH_DIAGNOSTICS
    [self registerDefaultOutputDiagnostics];
#endif
    
    return YES;
    
}

-(double)sampleRate{
    return _engineSampleRate;
}

#if ENABLE_OUTPUT_SWITCH_DIAGNOSTICS
// This listener only records state. It deliberately does not reconfigure audio.
-(void)registerDefaultOutputDiagnostics{
    if (_diagnosticDefaultOutputListenerRegistered){
        return;
    }

    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    __weak AudioEngine *weakSelf = self;
    _diagnosticDefaultOutputListener = ^(UInt32 numberAddresses,
                                         const AudioObjectPropertyAddress addresses[]) {
        AudioEngine *strongSelf = weakSelf;
        if (!strongSelf){
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            AudioDeviceID currentDefault = kAudioObjectUnknown;
            if ([strongSelf readDefaultOutputDevice:&currentDefault]){
                NSLog(@"Output diagnostics: defaultChanged configuredOutput=%u currentDefault=%u tapID=%u aggregateID=%u tapRate=%f",
                      strongSelf->_outputDeviceID, currentDefault, strongSelf->_tapID,
                      strongSelf->_aggregateID, strongSelf->_engineSampleRate);
                [strongSelf logOutputDevice:currentDefault context:@"defaultChanged"];
            }
        });
    };

    OSStatus ret = AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject,
                                                       &address,
                                                       _diagnosticsQueue,
                                                       _diagnosticDefaultOutputListener);
    if (FAILED(ret)){
        NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
        NSLog(@"Output diagnostics: failed to register default listener = %d(%@)",
              ret, [err description]);
        _diagnosticDefaultOutputListener = nil;
        return;
    }
    _diagnosticDefaultOutputListenerRegistered = YES;
    NSLog(@"Output diagnostics: default output listener registered");
}

-(void)unregisterDefaultOutputDiagnostics{
    if (!_diagnosticDefaultOutputListenerRegistered){
        return;
    }

    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    OSStatus ret = AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject,
                                                          &address,
                                                          _diagnosticsQueue,
                                                          _diagnosticDefaultOutputListener);
    if (FAILED(ret)){
        NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
        NSLog(@"Output diagnostics: failed to remove default listener = %d(%@)",
              ret, [err description]);
    }
    _diagnosticDefaultOutputListenerRegistered = NO;
    _diagnosticDefaultOutputListener = nil;
}

-(BOOL)readDefaultOutputDevice:(AudioDeviceID *)outputDeviceID{
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    UInt32 size = sizeof(*outputDeviceID);
    OSStatus ret = AudioObjectGetPropertyData(kAudioObjectSystemObject, &address,
                                              0, NULL, &size, outputDeviceID);
    if (FAILED(ret) || *outputDeviceID == kAudioObjectUnknown){
        NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
        NSLog(@"Output diagnostics: failed to read default output = %d(%@)",
              ret, [err description]);
        return NO;
    }
    return YES;
}

-(void)logOutputDevice:(AudioDeviceID)deviceID context:(NSString *)context{
    AudioObjectPropertyAddress address = {
        kAudioObjectPropertyName,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    CFStringRef name = NULL;
    UInt32 size = sizeof(name);
    OSStatus ret = AudioObjectGetPropertyData(deviceID, &address, 0, NULL, &size, &name);
    NSString *deviceName = !FAILED(ret) && name ? CFBridgingRelease(name) : @"<unavailable>";

    address.mSelector = kAudioDevicePropertyDeviceUID;
    CFStringRef uid = NULL;
    size = sizeof(uid);
    ret = AudioObjectGetPropertyData(deviceID, &address, 0, NULL, &size, &uid);
    NSString *deviceUID = !FAILED(ret) && uid ? CFBridgingRelease(uid) : @"<unavailable>";

    Float64 nominalRate = 0.0;
    size = sizeof(nominalRate);
    address.mSelector = kAudioDevicePropertyNominalSampleRate;
    ret = AudioObjectGetPropertyData(deviceID, &address, 0, NULL, &size, &nominalRate);
    if (FAILED(ret)){
        nominalRate = 0.0;
    }

    AudioStreamBasicDescription streamFormat = {0};
    size = sizeof(streamFormat);
    address.mSelector = kAudioDevicePropertyStreamFormat;
    address.mScope = kAudioDevicePropertyScopeOutput;
    ret = AudioObjectGetPropertyData(deviceID, &address, 0, NULL, &size, &streamFormat);
    if (FAILED(ret)){
        streamFormat.mSampleRate = 0.0;
    }

    NSLog(@"Output diagnostics: %@ id=%u name=%@ uid=%@ nominalRate=%f streamRate=%f",
          context, deviceID, deviceName, deviceUID, nominalRate, streamFormat.mSampleRate);
}
#endif

-(BOOL)createProcessTap{
    
    //Translate own PID to an AudioObjectID so we can exclude ourselves
    //(prevents the processed output from looping back into the tap)
    pid_t pid = getpid();
    AudioObjectID ownProcessObj = kAudioObjectUnknown;
    AudioObjectPropertyAddress propAddress;
    propAddress.mSelector = kAudioHardwarePropertyTranslatePIDToProcessObject;
    propAddress.mScope = kAudioObjectPropertyScopeGlobal;
    propAddress.mElement = kAudioObjectPropertyElementMain;
    UInt32 size = sizeof(ownProcessObj);
    OSStatus ret = AudioObjectGetPropertyData(kAudioObjectSystemObject, &propAddress,
                                              sizeof(pid), &pid, &size, &ownProcessObj);
    if (FAILED(ret) || ownProcessObj == kAudioObjectUnknown){
        NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
        NSLog(@"Failed to translate PID to process object = %d(%@)", ret, [err description]);
        return NO;
    }
    
    CFStringRef outputUID = NULL;
    size = sizeof(outputUID);
    propAddress.mSelector = kAudioDevicePropertyDeviceUID;
    propAddress.mScope = kAudioObjectPropertyScopeGlobal;
    propAddress.mElement = kAudioObjectPropertyElementMain;
    ret = AudioObjectGetPropertyData(_outputDeviceID, &propAddress, 0, NULL, &size, &outputUID);
    if (FAILED(ret) || outputUID == NULL){
        NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
        NSLog(@"Failed to get output device UID for tap = %d(%@)", ret, [err description]);
        return NO;
    }

    CATapDescription *desc = [[CATapDescription alloc]
                              initExcludingProcesses:@[ @(ownProcessObj) ]
                              andDeviceUID:(__bridge NSString *)outputUID
                              withStream:0];
    CFRelease(outputUID);
    desc.muteBehavior = CATapMutedWhenTapped;
    desc.privateTap = YES;
    desc.name = @"Scratch Now Tap";
    
    ret = AudioHardwareCreateProcessTap(desc, &_tapID);
    if (FAILED(ret) || _tapID == kAudioObjectUnknown){
        NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
        NSLog(@"Failed AudioHardwareCreateProcessTap = %d(%@)", ret, [err description]);
        return NO;
    }
    
    NSLog(@"Process tap created. tapID=%u", _tapID);
    return YES;
}

-(BOOL)readTapFormat{
    
    AudioObjectPropertyAddress propAddress;
    propAddress.mSelector = kAudioTapPropertyFormat;
    propAddress.mScope = kAudioObjectPropertyScopeGlobal;
    propAddress.mElement = kAudioObjectPropertyElementMain;
    
    UInt32 size = sizeof(_tapASBD);
    OSStatus ret = AudioObjectGetPropertyData(_tapID, &propAddress, 0, NULL, &size, &_tapASBD);
    if (FAILED(ret)){
        NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
        NSLog(@"Failed to get tap format = %d(%@)", ret, [err description]);
        return NO;
    }
    
    _engineSampleRate = _tapASBD.mSampleRate;
    
    NSLog(@"Tap format: rate=%f ch=%u flags=0x%x bytesPerFrame=%u",
          _tapASBD.mSampleRate, _tapASBD.mChannelsPerFrame,
          _tapASBD.mFormatFlags, _tapASBD.mBytesPerFrame);
    
    return YES;
}

-(BOOL)createAggregateDevice{
    
    //The aggregate must be anchored to a real output device as its main
    //sub-device; a tap-only aggregate silently produces zero samples.
    CFStringRef outputUID = NULL;
    UInt32 size = sizeof(outputUID);
    AudioObjectPropertyAddress propAddress;
    propAddress.mSelector = kAudioDevicePropertyDeviceUID;
    propAddress.mScope = kAudioObjectPropertyScopeGlobal;
    propAddress.mElement = kAudioObjectPropertyElementMain;
    OSStatus ret = AudioObjectGetPropertyData(_outputDeviceID, &propAddress, 0, NULL, &size, &outputUID);
    if (FAILED(ret) || outputUID == NULL){
        NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
        NSLog(@"Failed to get output device UID = %d(%@)", ret, [err description]);
        return NO;
    }
    
    //Tap UID (safer to read it back from the tap object than to rely on the description)
    CFStringRef tapUID = NULL;
    size = sizeof(tapUID);
    propAddress.mSelector = kAudioTapPropertyUID;
    ret = AudioObjectGetPropertyData(_tapID, &propAddress, 0, NULL, &size, &tapUID);
    if (FAILED(ret) || tapUID == NULL){
        NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
        NSLog(@"Failed to get tap UID = %d(%@)", ret, [err description]);
        CFRelease(outputUID);
        return NO;
    }
    
    NSDictionary *aggDesc = @{
        @kAudioAggregateDeviceNameKey          : @"Scratch Now Tap Aggregate",
        @kAudioAggregateDeviceUIDKey           : AGGREGATE_DEVICE_UID,
        @kAudioAggregateDeviceMainSubDeviceKey : (__bridge NSString *)outputUID,
        @kAudioAggregateDeviceIsPrivateKey     : @YES,
        @kAudioAggregateDeviceIsStackedKey     : @NO,
        @kAudioAggregateDeviceTapAutoStartKey  : @YES,
        @kAudioAggregateDeviceSubDeviceListKey : @[
            @{ @kAudioSubDeviceUIDKey : (__bridge NSString *)outputUID },
        ],
        @kAudioAggregateDeviceTapListKey       : @[
            @{ @kAudioSubTapUIDKey : (__bridge NSString *)tapUID,
               @kAudioSubTapDriftCompensationKey : @YES },
        ],
    };
    
    ret = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)aggDesc, &_aggregateID);
    CFRelease(outputUID);
    CFRelease(tapUID);
    
    if (FAILED(ret) || _aggregateID == kAudioObjectUnknown){
        NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
        NSLog(@"Failed AudioHardwareCreateAggregateDevice = %d(%@)", ret, [err description]);
        return NO;
    }
    
    NSLog(@"Aggregate device created. aggregateID=%u", _aggregateID);
    return YES;
}

-(BOOL)createIOProc{
    
    OSStatus ret = AudioDeviceCreateIOProcID(_aggregateID, TapIOProc,
                                             (__bridge void *)self, &_ioProcID);
    if (FAILED(ret) || _ioProcID == NULL){
        NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
        NSLog(@"Failed AudioDeviceCreateIOProcID = %d(%@)", ret, [err description]);
        return NO;
    }
    
    return YES;
}


- (BOOL)initializeOutput{
    OSStatus ret = noErr;
    
    ret = NewAUGraph(&_graph);
    if (FAILED(ret)) {
        NSLog(@"failed to create AU Graph");
        return NO;
    }
    ret = AUGraphOpen(_graph);
    if (FAILED(ret)) {
        NSLog(@"failed to open AU Graph");
        return NO;
    }
    
    AudioComponentDescription cd;
    
    cd.componentType = kAudioUnitType_Output;
    cd.componentSubType = kAudioUnitSubType_HALOutput;
    cd.componentManufacturer = kAudioUnitManufacturer_Apple;
    cd.componentFlags = 0;
    cd.componentFlagsMask = 0;
    AUNode outNode;
    ret = AUGraphAddNode(_graph, &cd, &outNode);
    if (FAILED(ret)){
        NSLog(@"failed to AUGraphAddNode");
        return NO;
    }
    ret = AUGraphNodeInfo(_graph, outNode, NULL, &_outUnit);
    if (FAILED(ret)){
        NSLog(@"failed to AUGraphNodeInfo");
        return NO;
    }
    
    
    //set callback to first unit
    AURenderCallbackStruct callbackInfo;
    callbackInfo.inputProc = MyRender;
    callbackInfo.inputProcRefCon = (__bridge void * _Nullable)(self);
    ret = AUGraphSetNodeInputCallback(_graph, outNode, 0, &callbackInfo);
    if (FAILED(ret)){
        NSLog(@"failed to set callback for Output");
        return NO;
    }
    
    AudioStreamBasicDescription asbd = {0};
    UInt32 size = sizeof(asbd);
    asbd.mSampleRate = _engineSampleRate;   // Follow the device-specific tap format.
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved;
    asbd.mBytesPerPacket = 4;
    asbd.mFramesPerPacket = 1;
    asbd.mBytesPerFrame = 4;
    asbd.mChannelsPerFrame = 2;
    asbd.mBitsPerChannel = 32;
    
    
    ret = AudioUnitSetProperty(_outUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd, size);
    if (FAILED(ret)){
        NSLog(@"failed to kAudioUnitProperty_StreamFormat for output(I)");
        return NO;
    }
    
    ret = AUGraphInitialize(_graph);
    if (FAILED(ret)){
        NSLog(@"failed to AUGraphInitialize");
        return NO;
    }
    
    return YES;
    
}


-(BOOL)setupLowLatencyOutput{
    AudioDeviceID builtInOutput = _outputDeviceID;

    OSStatus ret = AudioUnitSetProperty(_outUnit,
                               kAudioOutputUnitProperty_CurrentDevice,
                               kAudioUnitScope_Global,
                               0,
                               &builtInOutput,
                               sizeof(AudioDeviceID));
    if(FAILED(ret)){
        NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
        NSLog(@"Failed to set Device for Input = %d(%@)", ret, [err description]);
        return NO;
    }
    
    AudioObjectPropertyAddress propAddress;
    propAddress.mSelector = kAudioDevicePropertyBufferFrameSize;
    propAddress.mScope = kAudioObjectPropertyScopeGlobal;
    propAddress.mElement = kAudioObjectPropertyElementMaster;
    UInt32 frameSize = 32;
    ret = AudioObjectSetPropertyData(builtInOutput,
                                     &propAddress,0, NULL, sizeof(UInt32), &frameSize);
    if(FAILED(ret)){
        NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
        NSLog(@"Failed to set Device for Output = %d(%@)", ret, [err description]);
        return NO;
    }
    
    return YES;
}


-(BOOL)startOutput{
    
    if (_bIsPlaying){
        return YES;
    }
    
    
    OSStatus ret = AUGraphStart(_graph);
    if (FAILED(ret)){
        NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
        NSLog(@"Failed to get start input. err=%d(%@)", ret, [err description]);
        return NO;
    }
    _bIsPlaying = YES;
    return YES;
}

-(BOOL)stopOutput{
    _bIsPlaying = NO;
    OSStatus ret = AUGraphStop(_graph);
    if (FAILED(ret)){
        NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
        NSLog(@"Failed to get start input. err=%d(%@)", ret, [err description]);
        return NO;
    }
    return YES;
    
}

-(BOOL)startInput{
    //Note: this is the call that triggers the TCC dialog (System Audio Recording)
    OSStatus ret = AudioDeviceStart(_aggregateID, _ioProcID);
    if (FAILED(ret)){
        NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
        NSLog(@"Failed to start tap aggregate device. err=%d(%@)", ret, [err description]);
        return NO;
    }
    _bIsRecording = YES;
    NSLog(@"Tap aggregate device started");
    return YES;
}

-(BOOL)stopInput{
    _bIsRecording = NO;
    if (_aggregateID != kAudioObjectUnknown && _ioProcID != NULL){
        AudioDeviceStop(_aggregateID, _ioProcID);
    }
    
    return YES;
}

-(void)teardownInput{
#if ENABLE_OUTPUT_SWITCH_DIAGNOSTICS
    [self unregisterDefaultOutputDiagnostics];
#endif
    if (_aggregateID != kAudioObjectUnknown && _ioProcID != NULL){
        AudioDeviceDestroyIOProcID(_aggregateID, _ioProcID);
        _ioProcID = NULL;
    }
    if (_aggregateID != kAudioObjectUnknown){
        AudioHardwareDestroyAggregateDevice(_aggregateID);
        _aggregateID = kAudioObjectUnknown;
    }
    if (_tapID != kAudioObjectUnknown){
        AudioHardwareDestroyProcessTap(_tapID);
        _tapID = kAudioObjectUnknown;
    }
}


-(BOOL)isPlaying{
    return _bIsPlaying;
}

-(BOOL)isRecording{
    return _bIsRecording;
}

-(BOOL)obtainDefaultOutputDevice{
    AudioObjectPropertyAddress propAddress;
    propAddress.mSelector = kAudioHardwarePropertyDefaultOutputDevice;
    propAddress.mScope = kAudioObjectPropertyScopeGlobal;
    propAddress.mElement = kAudioObjectPropertyElementMaster;
    
    UInt32 size = sizeof(_outputDeviceID);
    OSStatus ret = AudioObjectGetPropertyData(kAudioObjectSystemObject,&propAddress,
                                              0, NULL, &size, &_outputDeviceID);
    
    if (0 < ret){
        NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
        NSLog(@"Failed to get Current output %d(%@)", ret, [err description]);
        return NO;
    }
#if ENABLE_OUTPUT_SWITCH_DIAGNOSTICS
    [self logOutputDevice:_outputDeviceID context:@"startupDefault"];
#endif
    return YES;
}


@end
