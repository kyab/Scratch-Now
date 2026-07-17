//
//  AppController.h
//  Scratch Now
//
//  Created by kyab on 2021/06/19.
//

#import <Foundation/Foundation.h>
#import <Cocoa/Cocoa.h>
#import "AudioEngine.h"
#import "RingBuffer.h"
#import "TurnTableView.h"

NS_ASSUME_NONNULL_BEGIN

@interface AppController : NSObject{
    AudioEngine *_ae;
    RingBuffer *_ring;
    __weak IBOutlet TurnTableView *_turnTableView;
    __weak IBOutlet NSSlider *_sliderDry;
    __weak IBOutlet NSButton *_btnStop;
    
    NSTimer *_tableStopTimer;
    Boolean _tableStopped;
    double _speedRate;
    
    
    float _dryVolume;
    float _wetVolume;
    
    float _tempLeftPtr[1024];
    float _tempRightPtr[1024];

    // Scratch processing state.
    Boolean _isScratchStarting;
    Boolean _isScratchEnding;
    Boolean _isFadingOut;
    Boolean _isFadingIn;
    UInt32 _fadeOutCounter;
    UInt32 _fadeInCounter;
    double _smoothedSpeed;
    double _subSamplePos;
    double _wetGain;
    float _dcInL;
    float _dcOutL;
    float _dcInR;
    float _dcOutR;
    Boolean _isScratching;
}

-(void)terminate;


@end

NS_ASSUME_NONNULL_END

