//
//  AudioEngine.m
//  MyPlaythrough
//
//  Created by kyab on 2017/05/15.
//  Copyright © 2017年 kyab. All rights reserved.
//

#import "AudioEngine.h"
#import <AudioToolbox/AudioToolbox.h>

#define OUTPUT_DEVICE @"Built-in Output"
//#define OUTPUT_DEVICE @"Soundflower (2ch)"
#define LOOPBACK_DEVICE @"Scratch Now"


@implementation AudioEngine
- (id)init
{
    self = [super init];
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

//notify to read
OSStatus MyRenderIn(void *inRefCon,
                    AudioUnitRenderActionFlags *ioActionFlags,
                    const AudioTimeStamp      *inTimeStamp,
                    UInt32 inBusNumber,
                    UInt32 inNumberFrames,
                    AudioBufferList *ioData){
    {
//                static UInt32 count = 0;
//                if ((count % 100) == 0){
//                    NSLog(@"LoopbackSide inputcallback inNumberFrames = %u", inNumberFrames);
//                }
//                count++;
    }
    
    AudioEngine *engine = (__bridge AudioEngine *)inRefCon;
    return [engine renderInput:ioActionFlags inTimeStamp:inTimeStamp inBusNumber:inBusNumber inNumberFrames:inNumberFrames ioData:ioData];
    
}


- (OSStatus) renderInput:(AudioUnitRenderActionFlags *)ioActionFlags inTimeStamp:(const AudioTimeStamp *) inTimeStamp inBusNumber:(UInt32) inBusNumber inNumberFrames:(UInt32)inNumberFrames ioData:(AudioBufferList *)ioData{
    

    return [_delegate inCallback:ioActionFlags inTimeStamp:inTimeStamp inBusNumber:inBusNumber inNumberFrames:inNumberFrames ioData:ioData];
    
}


//actual read from input. should be called from delegate's inCallback
//called from delegate callback
- (OSStatus) readFromInput:(AudioUnitRenderActionFlags *)ioActionFlags inTimeStamp:(const AudioTimeStamp *) inTimeStamp inBusNumber:(UInt32) inBusNumber inNumberFrames:(UInt32)inNumberFrames ioData:(AudioBufferList *)ioData{

    OSStatus ret = AudioUnitRender(_inputUnit,
                               ioActionFlags,
                               inTimeStamp,
                               inBusNumber,
                               inNumberFrames,
                               ioData
                               );
    if ( 0!=ret ){
        NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
        NSLog(@"Failed AudioUnitRender err=%d(%@)", ret, [err description]);
        return ret;
        
        //https://forum.juce.com/t/missing-kaudiounitproperty-maximumframesperslice/9109
        
    }
    
    return ret;
}



-(BOOL)initialize{
    if (![self obtainPreOutputDevice]){
        return NO;
    }
    
    if (![self initializeOutput]){
        return NO;
    }
    
    if (![self changeOutputDevice]){
        return NO;
    }
    
    if (![self initializeInput]){
        return NO;
    }
    
    if (![self setupVolumeSync]){
        //some device could not get device volume
        return YES;
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
    asbd.mSampleRate = 44100.0;
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


-(BOOL)initializeInput{
    OSStatus ret = noErr;
    
    AudioComponent component;
    AudioComponentDescription cd;
    cd.componentType = kAudioUnitType_Output;
    cd.componentSubType = kAudioUnitSubType_HALOutput;
    cd.componentManufacturer = kAudioUnitManufacturer_Apple;
    cd.componentFlags = 0;
    cd.componentFlagsMask = 0;
    component = AudioComponentFindNext(NULL, &cd);
    AudioComponentInstanceNew(component, &_inputUnit);
    ret = AudioUnitInitialize(_inputUnit);
    if (FAILED(ret)){
        NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
        NSLog(@"Failed to get input AU. err=%d(%@)", ret, [err description]);
        return NO;
    }
    
    if(![self setInputDevice]) return NO;
    if(![self setInputFormat]) return NO;
    if(![self setInputCallback]) return NO;
    
    return YES;
}

-(BOOL)setupVolumeSync{
    
    /*
     Some devices support volume control only via master channel. (BGM)
     Some devices support volume control only via each channel.  (Built-In Output)
     Some devices support both of master or channels.
     */
    AudioDeviceID bgm = [self getDeviceForName:LOOPBACK_DEVICE];

    Float32 scalar = 0;
    UInt32 size = sizeof(Float32);
    
    AudioObjectPropertyAddress propAddress;
    propAddress.mSelector = kAudioDevicePropertyVolumeScalar;
    propAddress.mScope = kAudioObjectPropertyScopeOutput;
    propAddress.mElement = 0; //use 1 and 2 for build in output
    
    if (0!=(AudioObjectGetPropertyData(bgm, &propAddress, 0, NULL, &size, &scalar))){
        NSLog(@"failed to get volume");
        return NO;
        
    }
    
    NSLog(@"Volume(Scalar) for BGM = %f", scalar);
    
    OSStatus ret = AudioObjectAddPropertyListener(bgm,&propAddress, PropListenerProc, (__bridge void *)self);
    
    if (0!=ret){
        NSLog(@"Failed to set notification");
        return NO;
    }
    
    return YES;
    
}


OSStatus PropListenerProc( AudioObjectID                       inObjectID,
                          UInt32                              inNumberAddresses,
                          const AudioObjectPropertyAddress*   inAddresses,
                          void* __nullable                    inClientData){
    AudioEngine *s = (__bridge AudioEngine *)inClientData;
    return [s propListenerProc:inObjectID inNumberAddresses:inNumberAddresses inAddresses:inAddresses];
}

-(OSStatus)propListenerProc:(AudioObjectID)inObjectId inNumberAddresses:(UInt32)inNumberAddresses inAddresses:(const AudioObjectPropertyAddress *)inAddresses{

    NSLog(@"volume changed");
    [self syncVolume];
    return noErr;
    
}

-(BOOL)syncVolume{
    AudioDeviceID bgm = [self getDeviceForName:LOOPBACK_DEVICE];

    Float32 scalar = 0;
    UInt32 size = sizeof(Float32);

    AudioObjectPropertyAddress propAddress;
    propAddress.mSelector = kAudioDevicePropertyVolumeScalar;
    propAddress.mScope = kAudioObjectPropertyScopeOutput;
    propAddress.mElement = 0; //use 1 and 2 for build in output

    if (0!=(AudioObjectGetPropertyData(bgm, &propAddress, 0, NULL, &size, &scalar))){
        NSLog(@"failed to get volume");
        return NO;
    }

    
    AudioDeviceID builtInOutput = [self getDeviceForName:OUTPUT_DEVICE];
    propAddress.mElement = 1;
    if (0!=(AudioObjectSetPropertyData(builtInOutput, &propAddress, 0, NULL, size, &scalar))){
        NSLog(@"failed to sync volume");
        return NO;
    }
    
    propAddress.mElement = 2;
    if (0!=(AudioObjectSetPropertyData(builtInOutput, &propAddress, 0, NULL, size, &scalar))){
        NSLog(@"failed to sync volume");
        return NO;
    }
    
    NSLog(@"Sync vol OK");
    return YES;

}



-(BOOL)changeOutputDevice{
    AudioDeviceID builtInOutput = _preOutputDeviceID;//[self getDeviceForName:OUTPUT_DEVICE];

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

- (Boolean)setInputDevice{
    OSStatus ret = noErr;
    
    //we should enable input and disable output at first.. shit! see TN2091.
    {
        UInt32 enableIO = 1;
        ret = AudioUnitSetProperty(_inputUnit,
                                   kAudioOutputUnitProperty_EnableIO,
                                   kAudioUnitScope_Input,
                                   1,   //input element
                                   &enableIO,
                                   sizeof(enableIO));
        if(FAILED(ret)){
            NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
            NSLog(@"Failed to kAudioOutputUnitProperty_EnableIO=%d(%@)", ret, [err description]);
            return NO;
        }
        
        enableIO = 0;
        ret = AudioUnitSetProperty(_inputUnit,
                                   kAudioOutputUnitProperty_EnableIO,
                                   kAudioUnitScope_Output,
                                   0,
                                   &enableIO,
                                   sizeof(enableIO));
        if(FAILED(ret)){
            NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
            NSLog(@"Failed to kAudioOutputUnitProperty_EnableIO=%d(%@)", ret, [err description]);
            return NO;
        }
    }
    
    AudioDeviceID inDevID = [self getDeviceForName:LOOPBACK_DEVICE];

    ret = AudioUnitSetProperty(_inputUnit,
                               kAudioOutputUnitProperty_CurrentDevice,
                               kAudioUnitScope_Global,
                               0,
                               &inDevID,
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
    ret = AudioObjectSetPropertyData(inDevID,
                                     &propAddress,0, NULL, sizeof(UInt32), &frameSize);
    if(FAILED(ret)){
        NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
        NSLog(@"Failed to set frame size for Input = %d(%@)", ret, [err description]);
            return NO;
    }
    
    
    
    return YES;
}


-(Boolean)setInputFormat {
    
    AudioStreamBasicDescription asbd = {0};
    UInt32 size = sizeof(asbd);
    asbd.mSampleRate = 44100.0;
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved;
    asbd.mBytesPerPacket = 4;
    asbd.mFramesPerPacket = 1;
    asbd.mBytesPerFrame = 4;
    asbd.mChannelsPerFrame = 2;
    asbd.mBitsPerChannel = 32;
    
    OSStatus ret = AudioUnitSetProperty(_inputUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &asbd, size);
    if(FAILED(ret)){
        NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
        NSLog(@"Failed to Set Format for Input side = %d(%@)", ret, [err description]);
        return NO;
    }
    
    return YES;
}


-(Boolean)setInputCallback{
    AURenderCallbackStruct callback;
    callback.inputProc = MyRenderIn;
    callback.inputProcRefCon = (__bridge void * _Nullable)(self);
    
    OSStatus ret = AudioUnitSetProperty(
                                        _inputUnit,
                                        kAudioOutputUnitProperty_SetInputCallback,
                                        kAudioUnitScope_Global,
                                        0,
                                        &callback,
                                        sizeof(callback));
    if(FAILED(ret)){
        NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
        NSLog(@"Failed to Set Input side callback = %d(%@)", ret, [err description]);
        return NO;
    }
    
    return YES;
    
}

- (AudioDeviceID)getDeviceForName:(NSString *)devName{
    OSStatus ret = noErr;
    UInt32 propertySize = 0;
    UInt32 num = 0;
    AudioDeviceID result = -1;
    
    AudioObjectPropertyAddress propAddress;
    propAddress.mSelector = kAudioHardwarePropertyDevices;
    propAddress.mScope = kAudioObjectPropertyScopeGlobal;
    propAddress.mElement = kAudioObjectPropertyElementMaster;
    
    ret = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &propAddress, 0, NULL, &propertySize);
    
    if(FAILED(ret)){
        NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
        NSLog(@"Failed to get datasize for devices = %d(%@)", ret, [err description]);
        return -1;
    }
    num = propertySize / sizeof(AudioObjectID);
    
    AudioObjectID *objects = (AudioObjectID *)malloc(propertySize);
    ret = AudioObjectGetPropertyData(kAudioObjectSystemObject, &propAddress, 0, NULL, &propertySize, objects);
    if(FAILED(ret)){
        NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
        NSLog(@"Failed to get devices = %d(%@)", ret, [err description]);
        free(objects);
        return -1;
    }
    
    for (int i = 0 ; i < num ; i++){
        CFStringRef name = NULL;
        propAddress.mSelector = kAudioObjectPropertyName;
        UInt32 size = sizeof(CFStringRef);
        ret = AudioObjectGetPropertyData(objects[i], &propAddress, 0, NULL,
                                         &size, &name);
        if(FAILED(ret)){
            NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
            NSLog(@"Failed to Get Name = %d(%@)", ret, [err description]);
            free(objects);
            return -1;
        }
        
        NSLog(@"dev : %@", name);
        
        if (name != NULL){
            if (CFStringCompare(name, (CFStringRef)devName,kCFCompareCaseInsensitive) == kCFCompareEqualTo){
                result = objects[i];
                break;
            }
            CFRelease(name);
        }
        
    }
    if (-1 == result){
        NSLog(@"No Scratch Now Driver found on system");
    }
    
    free(objects);
    return result;
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
    OSStatus ret = AudioOutputUnitStart(_inputUnit);
    if (FAILED(ret)){
        NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
        NSLog(@"Failed to get start input. err=%d(%@)", ret, [err description]);
        return NO;
    }
    _bIsRecording = YES;
    return YES;
}

-(BOOL)stopInput{
    _bIsRecording = NO;
    AudioOutputUnitStop(_inputUnit);
    
    return YES;
}


-(BOOL)isPlaying{
    return _bIsPlaying;
}

-(BOOL)isRecording{
    return _bIsRecording;
}

-(BOOL)obtainPreOutputDevice{
    AudioObjectPropertyAddress propAddress;
    propAddress.mSelector = kAudioHardwarePropertyDefaultOutputDevice;
    propAddress.mScope = kAudioObjectPropertyScopeGlobal;
    propAddress.mElement = kAudioObjectPropertyElementMaster;
    
    UInt32 size = sizeof(_preOutputDeviceID);
    OSStatus ret = AudioObjectGetPropertyData(kAudioObjectSystemObject,&propAddress,
                                              0, NULL, &size, &_preOutputDeviceID);
    
    if (0 < ret){
        NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
        NSLog(@"Failed to get Current output %d(%@)", ret, [err description]);
        return NO;
    }
    return YES;
}


//system output
-(BOOL)changeSystemOutputDeviceToBGM{
    
    AudioObjectPropertyAddress propAddress;
    propAddress.mSelector = kAudioHardwarePropertyDefaultOutputDevice;
    propAddress.mScope = kAudioObjectPropertyScopeGlobal;
    propAddress.mElement = kAudioObjectPropertyElementMaster;
    
    AudioDeviceID bgmOut = [self getDeviceForName:LOOPBACK_DEVICE];
    
    OSStatus ret = AudioObjectSetPropertyData(kAudioObjectSystemObject,
                                              &propAddress,
                                              0,
                                              NULL,
                                              sizeof(AudioObjectID),
                                              &bgmOut);
    if(0 < ret){
        NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
        NSLog(@"Failed to set Default output for BGM = %d(%@)", ret, [err description]);
        return NO;
    }
    
    return YES;

}
-(BOOL)restoreSystemOutputDevice{
    
    if (!_preOutputDeviceID) return YES;
    
    AudioObjectPropertyAddress propAddress;
    propAddress.mSelector = kAudioHardwarePropertyDefaultOutputDevice;
    propAddress.mScope = kAudioObjectPropertyScopeGlobal;
    propAddress.mElement = kAudioObjectPropertyElementMaster;

    OSStatus ret = AudioObjectSetPropertyData(kAudioObjectSystemObject,
                                     &propAddress,
                                     0,
                                     NULL,
                                     sizeof(AudioObjectID),
                                     &_preOutputDeviceID);
    if(0 < ret){
        NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
        NSLog(@"Failed to restore Default output for BGM = %d(%@)", ret, [err description]);
        return NO;
    }
    
    return YES;
}

-(NSArray *)listDevices:(BOOL)output{
    
    NSMutableArray *ar = [[NSMutableArray alloc] init];
    OSStatus ret = noErr;
    UInt32 propertySize = 0;
    UInt32 num = 0;
    
    AudioObjectPropertyAddress propAddress;
    propAddress.mSelector = kAudioHardwarePropertyDevices;
    propAddress.mScope = kAudioObjectPropertyScopeGlobal;
    propAddress.mElement = kAudioObjectPropertyElementMaster;
    
    ret = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &propAddress, 0, NULL, &propertySize);
    
    if(FAILED(ret)){
        NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
        NSLog(@"Failed to set Device for Input = %d(%@)", ret, [err description]);
        return nil;
    }
    num = propertySize / sizeof(AudioObjectID);
    
    AudioObjectID *objects = (AudioObjectID *)malloc(propertySize);
    ret = AudioObjectGetPropertyData(kAudioObjectSystemObject, &propAddress, 0, NULL, &propertySize, objects);
    if(FAILED(ret)){
        NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
        NSLog(@"Failed to set Device for Input = %d(%@)", ret, [err description]);
        free(objects);
        return nil;
    }
    
    for (int i = 0 ; i < num ; i++){
        CFStringRef name = NULL;
        propAddress.mSelector = kAudioObjectPropertyName;
        UInt32 size = sizeof(CFStringRef);
        ret = AudioObjectGetPropertyData(objects[i], &propAddress, 0, NULL,
                                         &size, &name);
        if(FAILED(ret)){
            NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
            NSLog(@"Failed to Get Name = %d(%@)", ret, [err description]);
            free(objects);
            return nil;
        }
        
        //Check input/output supported
        //kAudioDevicePropertyStreams AudioStreamID
        propAddress.mSelector = kAudioDevicePropertyStreams;
        if (output){
            propAddress.mScope = kAudioObjectPropertyScopeOutput;
        }else{
            propAddress.mScope = kAudioObjectPropertyScopeInput;
        }
        propAddress.mElement = kAudioObjectPropertyElementMaster;
        ret = AudioObjectGetPropertyDataSize(objects[i], &propAddress, 0, NULL, &propertySize);
        int num2 = propertySize / sizeof(AudioStreamID);
        if (num2 > 0 ){
            [ar addObject:(__bridge NSString *)name];
        }

        CFRelease(name);
        
    }
    free(objects);
    return [NSArray arrayWithArray:ar];
   
}

-(BOOL)changeInputDeviceTo:(NSString *)devName{
    
    AudioDeviceID devID = [self getDeviceForName:devName];
    if (devID == -1) {
        NSLog(@"Could not get device : %@", devName);
        return NO;
    }
    
    OSStatus ret = AudioUnitSetProperty(_inputUnit,
                               kAudioOutputUnitProperty_CurrentDevice,
                               kAudioUnitScope_Global,
                               0,
                               &devID,
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
    ret = AudioObjectSetPropertyData(devID,
                                     &propAddress,0, NULL, sizeof(UInt32), &frameSize);
    if(FAILED(ret)){
        NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
        NSLog(@"Failed to set Device for Input = %d(%@)", ret, [err description]);
        return NO;
    }
    
    
    return YES;
    
}
//
//-(BOOL)testAirPlay{
//    
//    //cant support AirPlay from 10.11!!!
//    //Apple dont allow me to enumurate AirPlay Devices,
//    //So it cant be settable as HAL Unit's kAudioOutputUnitProperty_CurrentDevice, nor System's Default Output Device.
//    // Suspecting iTunes uses some magic. Could not find any application that does magic to allow Output devices to AirPlay devices.
//    // Bug : https://forums.developer.apple.com/thread/17664
//    
//    
//    NSLog(@"testAirPlay");
//    
//    AudioObjectPropertyAddress propAddress;
//    propAddress.mSelector = kAudioHardwarePropertyTranslateUIDToDevice;
//    propAddress.mScope = kAudioObjectPropertyScopeGlobal;
//    propAddress.mElement = kAudioObjectPropertyElementMaster;
//    
//    CFStringRef airplayDeviceUID = CFSTR("AirPlay");
//    UInt32 dataSize = 0;
//    OSStatus ret;
//    ret = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &propAddress, sizeof(CFStringRef),
//                                         &airplayDeviceUID, &dataSize);
//    
//    if (FAILED(ret)){
//        NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
//        NSLog(@"Failed to get Device for AirPlay = %d(%@)", ret, [err description]);
//        return NO;
//    }
//    
//    
//    AudioDeviceID airplayDeviceId;
//    ret = AudioObjectGetPropertyData(kAudioObjectSystemObject,
//                                     &propAddress,
//                                     sizeof(CFStringRef),
//                                     &airplayDeviceUID,
//                                     &dataSize,
//                                     &airplayDeviceId);
//    
//    if (FAILED(ret)){
//        NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
//        NSLog(@"Failed to get Device for AirPlay 2 = %d(%@)", ret, [err description]);
//        return NO;
//    }
//    
//    NSLog(@"deviceId for AirPlay = 0x%x", airplayDeviceId);
//    
//    
//    CFStringRef name = NULL;
//    propAddress.mSelector = kAudioObjectPropertyName;
//    UInt32 size = sizeof(CFStringRef);
//    ret = AudioObjectGetPropertyData(airplayDeviceId, &propAddress, 0, NULL, &size, &name);
//    if (FAILED(ret)){
//        NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
//        NSLog(@"Failed to Get Name = %d(%@)", ret, [err description]);
//        return NO;
//    }
//    
//    
//    
//    return YES;
//    
//    
//}


@end

