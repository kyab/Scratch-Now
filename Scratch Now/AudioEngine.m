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
#import <os/log.h>
#import <stdio.h>
#import <string.h>
#import <unistd.h>

#define ENABLE_OUTPUT_SWITCH_DIAGNOSTICS 0
#define OUTPUT_VOLUME_FADE_STEPS 10
#define OUTPUT_VOLUME_FADE_STEP_US 10000
#define OUTPUT_VOLUME_SETTLE_US 100000
#define OUTPUT_VOLUME_MAX_CHANNELS 8

typedef struct {
    UInt32 count;
    AudioObjectPropertyElement elements[OUTPUT_VOLUME_MAX_CHANNELS];
    Float32 values[OUTPUT_VOLUME_MAX_CHANNELS];
} OutputVolumeSnapshot;

static os_log_t OutputDiagnosticsLog(void){
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.kyab.ScratchNow", "output-diagnostics");
    });
    return log;
}

#define OUTPUT_DIAGNOSTIC_LOG(format, ...) \
    os_log_with_type(OutputDiagnosticsLog(), OS_LOG_TYPE_DEFAULT, format, ##__VA_ARGS__)

// Aggregate IOProc input lists subdevice input streams first, then the tap.
// Interleaved tap: one buffer at the end (L,R,L,R,...).
// Non-interleaved tap: one mono buffer per channel at the end (L buffer, then R, ...).
static BOOL TapFormatIsNonInterleaved(const AudioStreamBasicDescription *asbd){
    return (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
}

static UInt32 TapFormatChannelCount(const AudioStreamBasicDescription *asbd){
    return asbd->mChannelsPerFrame > 0 ? asbd->mChannelsPerFrame : 1;
}

static UInt32 TapFirstBufferIndex(const AudioBufferList *abl,
                                  const AudioStreamBasicDescription *tapASBD){
    UInt32 bufferCount = abl->mNumberBuffers;
    if (TapFormatIsNonInterleaved(tapASBD)){
        UInt32 tapChannels = TapFormatChannelCount(tapASBD);
        if (bufferCount >= tapChannels){
            return bufferCount - tapChannels;
        }
    }
    return bufferCount - 1;
}

#if SCRATCH_NOW_TAP_SMOKE_CI
// Tap smoke CI only: append one status line per second to a JSONL file so the
// external harness can confirm the tap is delivering (non-silent) audio and
// that changes in the played tone are followed with a small delay.
// This whole block is compiled out of Debug/Release builds.
static NSString *TapSmokeCIStatusPath(void){
    static NSString *path;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *dir = @"/tmp/scratch-now-tap-smoke-ci";
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];
        path = [dir stringByAppendingPathComponent:@"tap.jsonl"];
    });
    return path;
}

// Append a single JSON line. Opened/closed each second so a crash still leaves
// a readable file for CI artifacts.
static void TapSmokeCIAppendStatus(double ts, float peak, float rms,
                                   unsigned long long framesTotal, double estimatedHz){
    NSString *line = [NSString stringWithFormat:
                      @"{\"ts\":%.3f,\"peak\":%.6f,\"rms\":%.6f,\"framesTotal\":%llu,\"estimatedHz\":%.2f}\n",
                      ts, peak, rms, framesTotal, estimatedHz];
    const char *utf8 = [line UTF8String];
    FILE *f = fopen([TapSmokeCIStatusPath() fileSystemRepresentation], "a");
    if (f){
        fwrite(utf8, 1, strlen(utf8), f);
        fclose(f);
    }
}
#endif

@interface AudioEngine ()
- (void)registerDefaultOutputListener;
- (void)unregisterDefaultOutputListener;
- (void)registerOutputSampleRateListener;
- (void)unregisterOutputSampleRateListener;
- (BOOL)readDefaultOutputDevice:(AudioDeviceID *)outputDeviceID;
- (void)logOutputDevice:(AudioDeviceID)deviceID context:(NSString *)context;
- (BOOL)buildPipeline;
- (BOOL)setupAggregateBufferFrameSize;
- (void)rebuildPipelineForOutputConfigurationChangeFromDevice:(AudioDeviceID)sourceDevice;
- (void)teardownCapturePath;
- (void)teardownOutput;
- (BOOL)captureOutputVolume:(OutputVolumeSnapshot *)snapshot;
- (void)applyOutputVolume:(const OutputVolumeSnapshot *)snapshot scale:(Float32)scale;
- (void)fadeOutputVolume:(const OutputVolumeSnapshot *)snapshot fromScale:(Float32)fromScale toScale:(Float32)toScale;
@end


@implementation AudioEngine
- (id)init
{
    self = [super init];
    _tapID = kAudioObjectUnknown;
    _aggregateID = kAudioObjectUnknown;
    _ioProcID = NULL;
    _graph = NULL;
    _outUnit = NULL;
    _defaultOutputListenerQueue = dispatch_queue_create("com.kyab.ScratchNow.output-listener",
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
    if (_isReconfiguring || _isTerminating){
        for (UInt32 i = 0; i < ioData->mNumberBuffers; i++){
            bzero(ioData->mBuffers[i].mData, ioData->mBuffers[i].mDataByteSize);
        }
        return noErr;
    }
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
    if (_isReconfiguring || _isTerminating){
        return noErr;
    }
    if (!inInputData || inInputData->mNumberBuffers == 0){
        return noErr;
    }
    
    // Skip any leading subdevice input buffers; the tap occupies the tail.
    UInt32 tapBufferIndex = TapFirstBufferIndex(inInputData, &_tapASBD);
    const AudioBuffer *tapBuf = &inInputData->mBuffers[tapBufferIndex];
    UInt32 bytesPerFrame = tapBuf->mNumberChannels * sizeof(float);
    if (bytesPerFrame == 0){
        return noErr;
    }
    UInt32 frames = tapBuf->mDataByteSize / bytesPerFrame;
    if (frames == 0){
        return noErr;
    }

#if ENABLE_OUTPUT_SWITCH_DIAGNOSTICS
    // Temporary once-per-second capture proof for the hardware baseline.
    {
        static UInt32 frameCounter = 0;
        static float peak = 0.0f;
        const float *p = (const float *)tapBuf->mData;
        UInt32 n = tapBuf->mDataByteSize / sizeof(float);
        for (UInt32 i = 0; i < n; i++){
            float v = fabsf(p[i]);
            if (v > peak) peak = v;
        }
        frameCounter += frames;
        if (frameCounter >= (UInt32)_engineSampleRate){
            OUTPUT_DIAGNOSTIC_LOG("tapCapture peak=%{public}.6f framesPerCallback=%u buffers=%u channels=%u configuredOutput=%u",
                                  peak, frames, inInputData->mNumberBuffers,
                                  tapBuf->mNumberChannels, _outputDeviceID);
            frameCounter = 0;
            peak = 0.0f;
        }
    }
#endif

#if SCRATCH_NOW_TAP_SMOKE_CI
    // Tap smoke CI: accumulate peak/rms and a rough dominant-frequency estimate
    // (zero crossings on the first channel) and flush once per second.
    {
        static UInt32 frameCounter = 0;
        static unsigned long long framesTotal = 0;
        static float peak = 0.0f;
        static double sumSquares = 0.0;
        static unsigned long long squareCount = 0;
        static UInt32 zeroCrossings = 0;

        const float *p = (const float *)tapBuf->mData;
        UInt32 channels = tapBuf->mNumberChannels > 0 ? tapBuf->mNumberChannels : 1;
        UInt32 n = tapBuf->mDataByteSize / sizeof(float);
        for (UInt32 i = 0; i < n; i++){
            float v = p[i];
            float a = fabsf(v);
            if (a > peak) peak = a;
            sumSquares += (double)v * (double)v;
            squareCount++;
        }
        // Count zero crossings on channel 0 only (interleaved or mono).
        // Schmitt-trigger state rejects HF chatter around zero without requiring
        // a single-sample jump across the full hysteresis band.
        const float kZcrHysteresis = 0.02f;
        static int zcrState = 0; // -1 below low threshold, +1 above high threshold
        for (UInt32 i = 0; i < n; i += channels){
            float v = p[i];
            if (zcrState <= 0 && v >= kZcrHysteresis){
                zcrState = 1;
                zeroCrossings++;
            } else if (zcrState >= 0 && v <= -kZcrHysteresis){
                zcrState = -1;
                zeroCrossings++;
            }
        }

        frameCounter += frames;
        framesTotal += frames;
        if (frameCounter >= (UInt32)_engineSampleRate && _engineSampleRate > 0){
            double rms = squareCount > 0 ? sqrt(sumSquares / (double)squareCount) : 0.0;
            // Two zero crossings per period, over ~one second worth of frames.
            double estimatedHz = ((double)zeroCrossings / 2.0)
                * (_engineSampleRate / (double)frameCounter);
            TapSmokeCIAppendStatus(CFAbsoluteTimeGetCurrent(), peak, (float)rms,
                                   framesTotal, estimatedHz);
            frameCounter = 0;
            peak = 0.0f;
            sumSquares = 0.0;
            squareCount = 0;
            zeroCrossings = 0;
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
    UInt32 tapBufferIndex = TapFirstBufferIndex(src, &_tapASBD);

    if (TapFormatIsNonInterleaved(&_tapASBD)){
        // Tail buffers are one channel each: [..., L, R].
        const float *srcL = (const float *)src->mBuffers[tapBufferIndex].mData;
        memcpy(dstL, srcL, sizeof(float)*frames);
        UInt32 tapChannels = TapFormatChannelCount(&_tapASBD);
        if (tapChannels >= 2 && (tapBufferIndex + 1) < src->mNumberBuffers){
            memcpy(dstR, src->mBuffers[tapBufferIndex + 1].mData, sizeof(float)*frames);
        }else{
            memcpy(dstR, srcL, sizeof(float)*frames);
        }
    }else{
        // Last buffer is interleaved stereo (or mono).
        const AudioBuffer *tapBuf = &src->mBuffers[tapBufferIndex];
        const float *p = (const float *)tapBuf->mData;
        UInt32 ch = tapBuf->mNumberChannels > 0 ? tapBuf->mNumberChannels : 1;
        if (ch >= 2){
            for (UInt32 i = 0; i < frames; i++){
                dstL[i] = p[ch * i];
                dstR[i] = p[ch * i + 1];
            }
        }else{
            memcpy(dstL, p, sizeof(float)*frames);
            memcpy(dstR, p, sizeof(float)*frames);
        }
    }
    
    if (frames < inNumberFrames){
        bzero(dstL + frames, sizeof(float)*(inNumberFrames - frames));
        bzero(dstR + frames, sizeof(float)*(inNumberFrames - frames));
    }
    
    return noErr;
}



-(BOOL)initialize{
    if (![self buildPipeline]){
        [self teardownCapturePath];
        [self teardownOutput];
        return NO;
    }

    [self registerDefaultOutputListener];
    [self registerOutputSampleRateListener];
    return YES;
}

// Create every resource that is tied to the current default output device.
-(BOOL)buildPipeline{
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
    
    if (![self setupAggregateBufferFrameSize]){
        return NO;
    }
    
    if (![self createIOProc]){
        return NO;
    }
    
    return YES;
}

-(double)sampleRate{
    return _engineSampleRate;
}

// The listener forwards work to the main thread and never rebuilds on a Core Audio queue.
-(void)registerDefaultOutputListener{
    if (_defaultOutputListenerRegistered){
        return;
    }

    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    __weak AudioEngine *weakSelf = self;
    _defaultOutputListener = ^(UInt32 numberAddresses,
                               const AudioObjectPropertyAddress addresses[]) {
        AudioEngine *strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_isTerminating){
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (!strongSelf->_isTerminating){
                [strongSelf rebuildPipelineForOutputConfigurationChangeFromDevice:kAudioObjectUnknown];
            }
        });
    };

    OSStatus ret = AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject,
                                                       &address,
                                                       _defaultOutputListenerQueue,
                                                       _defaultOutputListener);
    if (FAILED(ret)){
        OUTPUT_DIAGNOSTIC_LOG("failed to register default output listener status=%d",
                              ret);
        _defaultOutputListener = nil;
        return;
    }
    _defaultOutputListenerRegistered = YES;
    OUTPUT_DIAGNOSTIC_LOG("default output listener registered");
}

-(void)unregisterDefaultOutputListener{
    if (!_defaultOutputListenerRegistered){
        return;
    }

    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    OSStatus ret = AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject,
                                                          &address,
                                                          _defaultOutputListenerQueue,
                                                          _defaultOutputListener);
    if (FAILED(ret)){
        OUTPUT_DIAGNOSTIC_LOG("failed to remove default output listener status=%d",
                              ret);
    }
    _defaultOutputListenerRegistered = NO;
    _defaultOutputListener = nil;
}

-(void)registerOutputSampleRateListener{
    if (_outputSampleRateListenerRegistered || _outputDeviceID == kAudioObjectUnknown){
        return;
    }

    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    AudioDeviceID observedDeviceID = _outputDeviceID;
    __weak AudioEngine *weakSelf = self;
    _outputSampleRateListener = ^(UInt32 numberAddresses,
                                  const AudioObjectPropertyAddress addresses[]) {
        AudioEngine *strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_isTerminating){
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (!strongSelf->_isTerminating){
                [strongSelf rebuildPipelineForOutputConfigurationChangeFromDevice:observedDeviceID];
            }
        });
    };

    OSStatus ret = AudioObjectAddPropertyListenerBlock(observedDeviceID,
                                                       &address,
                                                       _defaultOutputListenerQueue,
                                                       _outputSampleRateListener);
    if (FAILED(ret)){
        OUTPUT_DIAGNOSTIC_LOG("failed to register output sample rate listener status=%d",
                              ret);
        _outputSampleRateListener = nil;
        return;
    }
    _outputSampleRateListenerRegistered = YES;
    OUTPUT_DIAGNOSTIC_LOG("output sample rate listener registered output=%u",
                          observedDeviceID);
}

-(void)unregisterOutputSampleRateListener{
    if (!_outputSampleRateListenerRegistered){
        return;
    }

    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    OSStatus ret = AudioObjectRemovePropertyListenerBlock(_outputDeviceID,
                                                          &address,
                                                          _defaultOutputListenerQueue,
                                                          _outputSampleRateListener);
    if (FAILED(ret)){
        OUTPUT_DIAGNOSTIC_LOG("failed to remove output sample rate listener status=%d",
                              ret);
    }
    _outputSampleRateListenerRegistered = NO;
    _outputSampleRateListener = nil;
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
        OUTPUT_DIAGNOSTIC_LOG("failed to read default output status=%d",
                              ret);
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

    OUTPUT_DIAGNOSTIC_LOG("%{public}@ id=%u name=%{public}@ uid=%{public}@ nominalRate=%{public}.1f streamRate=%{public}.1f",
                          context, deviceID, deviceName, deviceUID, nominalRate,
                          streamFormat.mSampleRate);
}

-(void)rebuildPipelineForOutputConfigurationChangeFromDevice:(AudioDeviceID)sourceDevice{
    if (_isReconfiguring || _isTerminating){
        return;
    }

    AudioDeviceID currentDefault = kAudioObjectUnknown;
    if (![self readDefaultOutputDevice:&currentDefault]){
        return;
    }
    if (currentDefault == _outputDeviceID &&
        (sourceDevice == kAudioObjectUnknown || sourceDevice != _outputDeviceID)){
        return;
    }

    _isReconfiguring = YES;
    BOOL wasPlaying = _bIsPlaying;
    BOOL wasRecording = _bIsRecording;
    OUTPUT_DIAGNOSTIC_LOG("rebuildStarted oldOutput=%u newOutput=%u sourceOutput=%u oldRate=%{public}.1f",
                          _outputDeviceID, currentDefault, sourceDevice, _engineSampleRate);

    [self stopInput];
    [self stopOutput];
    [self unregisterOutputSampleRateListener];
    [self teardownCapturePath];
    [self teardownOutput];

    if (![self buildPipeline]){
        [self teardownCapturePath];
        [self teardownOutput];
        OUTPUT_DIAGNOSTIC_LOG("rebuildFailed newOutput=%u", currentDefault);
        _isReconfiguring = NO;
        return;
    }

    [self registerOutputSampleRateListener];
    if ([_delegate respondsToSelector:@selector(audioEngineDidRebuildPipeline:)]){
        [_delegate audioEngineDidRebuildPipeline:self];
    }

    if (wasPlaying && ![self startOutput]){
        OUTPUT_DIAGNOSTIC_LOG("rebuildFailedToRestartOutput output=%u", _outputDeviceID);
    }
    if (wasRecording && ![self startInput]){
        OUTPUT_DIAGNOSTIC_LOG("rebuildFailedToRestartInput output=%u", _outputDeviceID);
    }

    OUTPUT_DIAGNOSTIC_LOG("rebuildFinished output=%u rate=%{public}.1f",
                          _outputDeviceID, _engineSampleRate);
    _isReconfiguring = NO;
}

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
    
    NSString *aggregateUID = [NSString stringWithFormat:@"com.kyab.Scratch-Now.tap-aggregate.%@",
                              [NSUUID UUID].UUIDString];
    NSDictionary *aggDesc = @{
        @kAudioAggregateDeviceNameKey          : @"Scratch Now Tap Aggregate",
        @kAudioAggregateDeviceUIDKey           : aggregateUID,
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

// Request a smaller IO period on the tap aggregate.
-(BOOL)setupAggregateBufferFrameSize{
    const UInt32 desiredFrameSize = 64;
    
    AudioObjectPropertyAddress propAddress;
    propAddress.mSelector = kAudioDevicePropertyBufferFrameSizeRange;
    propAddress.mScope = kAudioObjectPropertyScopeGlobal;
    propAddress.mElement = kAudioObjectPropertyElementMain;
    
    AudioValueRange range = {0};
    UInt32 size = sizeof(range);
    OSStatus ret = AudioObjectGetPropertyData(_aggregateID, &propAddress, 0, NULL, &size, &range);
    if (FAILED(ret)){
        NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
        NSLog(@"Failed to get aggregate BufferFrameSizeRange = %d(%@)", ret, [err description]);
        return NO;
    }
    
    NSLog(@"Aggregate BufferFrameSizeRange: min=%.0f max=%.0f (desired=%u)",
          range.mMinimum, range.mMaximum, desiredFrameSize);
    
    if ((Float64)desiredFrameSize < range.mMinimum ||
        (Float64)desiredFrameSize > range.mMaximum){
        NSLog(@"Desired BufferFrameSize %u is outside aggregate range [%.0f, %.0f]",
              desiredFrameSize, range.mMinimum, range.mMaximum);
        return NO;
    }
    
    propAddress.mSelector = kAudioDevicePropertyBufferFrameSize;
    UInt32 frameSize = desiredFrameSize;
    ret = AudioObjectSetPropertyData(_aggregateID, &propAddress, 0, NULL,
                                     sizeof(frameSize), &frameSize);
    if (FAILED(ret)){
        NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
        NSLog(@"Failed to set aggregate BufferFrameSize=%u = %d(%@)",
              desiredFrameSize, ret, [err description]);
        return NO;
    }
    
    UInt32 actualFrameSize = 0;
    size = sizeof(actualFrameSize);
    ret = AudioObjectGetPropertyData(_aggregateID, &propAddress, 0, NULL, &size, &actualFrameSize);
    if (FAILED(ret)){
        NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
        NSLog(@"Failed to read back aggregate BufferFrameSize = %d(%@)", ret, [err description]);
        return NO;
    }
    
    if (actualFrameSize != desiredFrameSize){
        NSLog(@"Aggregate BufferFrameSize mismatch: desired=%u actual=%u",
              desiredFrameSize, actualFrameSize);
        return NO;
    }
    
    NSLog(@"Aggregate BufferFrameSize set to %u", actualFrameSize);
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
    
    
    //set callback to supply our audio data
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


-(BOOL)readOutputVolumeElement:(AudioObjectPropertyElement)element value:(Float32 *)value{
    if (_outputDeviceID == kAudioObjectUnknown || !value){
        return NO;
    }

    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyVolumeScalar,
        kAudioObjectPropertyScopeOutput,
        element,
    };
    if (!AudioObjectHasProperty(_outputDeviceID, &address)){
        return NO;
    }
    Boolean settable = NO;
    OSStatus ret = AudioObjectIsPropertySettable(_outputDeviceID, &address, &settable);
    if (FAILED(ret) || !settable){
        return NO;
    }

    UInt32 size = sizeof(Float32);
    ret = AudioObjectGetPropertyData(_outputDeviceID, &address, 0, NULL, &size, value);
    return !FAILED(ret);
}

-(BOOL)captureOutputVolume:(OutputVolumeSnapshot *)snapshot{
    if (!snapshot){
        return NO;
    }
    memset(snapshot, 0, sizeof(*snapshot));

    Float32 master = 0.0f;
    if ([self readOutputVolumeElement:kAudioObjectPropertyElementMain value:&master]){
        snapshot->elements[0] = kAudioObjectPropertyElementMain;
        snapshot->values[0] = master;
        snapshot->count = 1;
        return YES;
    }

    for (AudioObjectPropertyElement element = 1; element <= OUTPUT_VOLUME_MAX_CHANNELS; element++){
        Float32 value = 0.0f;
        if (![self readOutputVolumeElement:element value:&value]){
            continue;
        }
        snapshot->elements[snapshot->count] = element;
        snapshot->values[snapshot->count] = value;
        snapshot->count++;
    }
    return snapshot->count > 0;
}

-(void)applyOutputVolume:(const OutputVolumeSnapshot *)snapshot scale:(Float32)scale{
    if (!snapshot || snapshot->count == 0 || _outputDeviceID == kAudioObjectUnknown){
        return;
    }
    if (scale < 0.0f) scale = 0.0f;
    if (scale > 1.0f) scale = 1.0f;

    for (UInt32 i = 0; i < snapshot->count; i++){
        Float32 value = snapshot->values[i] * scale;
        AudioObjectPropertyAddress address = {
            kAudioDevicePropertyVolumeScalar,
            kAudioObjectPropertyScopeOutput,
            snapshot->elements[i],
        };
        AudioObjectSetPropertyData(_outputDeviceID, &address, 0, NULL, sizeof(Float32), &value);
    }
}

-(void)fadeOutputVolume:(const OutputVolumeSnapshot *)snapshot fromScale:(Float32)fromScale toScale:(Float32)toScale{
    if (!snapshot || snapshot->count == 0){
        return;
    }
    for (UInt32 step = 1; step <= OUTPUT_VOLUME_FADE_STEPS; step++){
        Float32 t = (Float32)step / (Float32)OUTPUT_VOLUME_FADE_STEPS;
        [self applyOutputVolume:snapshot scale:(fromScale + (toScale - fromScale) * t)];
        usleep(OUTPUT_VOLUME_FADE_STEP_US);
    }
}

-(BOOL)startOutput{
    if (_bIsPlaying){
        return YES;
    }
    if (_graph == NULL){
        NSLog(@"Cannot start output without an audio graph");
        return NO;
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
    if (_graph == NULL){
        return YES;
    }
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
    if (_bIsRecording){
        return YES;
    }
    if (_aggregateID == kAudioObjectUnknown || _ioProcID == NULL){
        NSLog(@"Cannot start input without a tap aggregate device");
        return NO;
    }

    // Fade the hardware output to silence first so CATapMutedWhenTapped
    // engages at zero instead of cutting mid-waveform.
    OutputVolumeSnapshot volume = {0};
    BOOL fadedVolume = [self captureOutputVolume:&volume];
    if (fadedVolume){
        [self fadeOutputVolume:&volume fromScale:1.0f toScale:0.0f];
        usleep(OUTPUT_VOLUME_SETTLE_US);
    }

    OSStatus ret = AudioDeviceStart(_aggregateID, _ioProcID);
    if (FAILED(ret)){
        if (fadedVolume){
            [self applyOutputVolume:&volume scale:1.0f];
        }
        NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
        NSLog(@"Failed to start tap aggregate device. err=%d(%@)", ret, [err description]);
        return NO;
    }

    if (fadedVolume){
        usleep(OUTPUT_VOLUME_SETTLE_US);
        [self fadeOutputVolume:&volume fromScale:0.0f toScale:1.0f];
    }
    _bIsRecording = YES;
    NSLog(@"Tap aggregate device started");
    return YES;
}

-(BOOL)stopInput{
    BOOL wasRecording = _bIsRecording;
    _bIsRecording = NO;
    if (_aggregateID == kAudioObjectUnknown || _ioProcID == NULL){
        return YES;
    }

    OutputVolumeSnapshot volume = {0};
    BOOL fadedVolume = NO;
    if (wasRecording){
        fadedVolume = [self captureOutputVolume:&volume];
        if (fadedVolume){
            [self fadeOutputVolume:&volume fromScale:1.0f toScale:0.0f];
            usleep(OUTPUT_VOLUME_SETTLE_US);
        }
    }

    OSStatus ret = AudioDeviceStop(_aggregateID, _ioProcID);
    if (FAILED(ret)){
        if (fadedVolume){
            [self applyOutputVolume:&volume scale:1.0f];
        }
        NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
        NSLog(@"Failed to stop tap aggregate device = %d(%@)", ret, [err description]);
        return NO;
    }

    if (fadedVolume){
        [self fadeOutputVolume:&volume fromScale:0.0f toScale:1.0f];
    }
    return YES;
}

-(void)teardownCapturePath{
    if (_aggregateID != kAudioObjectUnknown && _ioProcID != NULL){
        OSStatus ret = AudioDeviceDestroyIOProcID(_aggregateID, _ioProcID);
        if (FAILED(ret)){
            NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
            NSLog(@"Failed to destroy tap IOProc = %d(%@)", ret, [err description]);
        }
        _ioProcID = NULL;
    }
    if (_aggregateID != kAudioObjectUnknown){
        OSStatus ret = AudioHardwareDestroyAggregateDevice(_aggregateID);
        if (FAILED(ret)){
            NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
            NSLog(@"Failed to destroy tap aggregate device = %d(%@)", ret, [err description]);
        }
        _aggregateID = kAudioObjectUnknown;
    }
    if (_tapID != kAudioObjectUnknown){
        OSStatus ret = AudioHardwareDestroyProcessTap(_tapID);
        if (FAILED(ret)){
            NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
            NSLog(@"Failed to destroy process tap = %d(%@)", ret, [err description]);
        }
        _tapID = kAudioObjectUnknown;
    }
}

-(void)teardownOutput{
    if (_graph == NULL){
        _outUnit = NULL;
        return;
    }

    OSStatus ret = AUGraphUninitialize(_graph);
    if (FAILED(ret)){
        NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
        NSLog(@"Failed to uninitialize output graph = %d(%@)", ret, [err description]);
    }
    ret = DisposeAUGraph(_graph);
    if (FAILED(ret)){
        NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain code:ret userInfo:nil];
        NSLog(@"Failed to dispose output graph = %d(%@)", ret, [err description]);
    }
    _graph = NULL;
    _outUnit = NULL;
}

-(void)shutdown{
    if (_isTerminating){
        return;
    }

    _isTerminating = YES;
    [self unregisterOutputSampleRateListener];
    [self unregisterDefaultOutputListener];
    [self stopInput];
    [self stopOutput];
    [self teardownCapturePath];
    [self teardownOutput];
}


-(BOOL)isPlaying{
    return _bIsPlaying;
}

-(BOOL)isRecording{
    return _bIsRecording;
}

-(BOOL)obtainDefaultOutputDevice{
    if (![self readDefaultOutputDevice:&_outputDeviceID]){
        return NO;
    }
    [self logOutputDevice:_outputDeviceID context:@"pipelineDefault"];
    return YES;
}


@end
