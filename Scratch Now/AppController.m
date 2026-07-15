//
//  AppController.m
//  Scratch Now
//
//  Created by kyab on 2021/06/19.
//

#import "AppController.h"

@implementation AppController

-(void)awakeFromNib{
    // Initialize the engine first: the device-specific tap decides the pipeline
    // sample rate, which the ring buffer allocation depends on.
    _ae = [[AudioEngine alloc] init];
    if([_ae initialize]){
        NSLog(@"AudioEngine all OK");
    }

    _pipeline = [[ScratchPipeline alloc] initWithSampleRate:[_ae sampleRate]];

    _ae.inputConsumer = _pipeline;
    _ae.outputRenderer = _pipeline;
    _ae.rebuildDelegate = self;

    [_turnTableView setRingBuffer:[_pipeline ring]];
    [_turnTableView setDelegate:self];
    [_turnTableView start];

    [_ae startPlayback];
    [_ae startCapture];
}

// The engine has stopped its audio callbacks before this notification.
- (void)audioEngineDidRebuildPipeline:(AudioEngine *)engine{
    [_pipeline reconfigureWithSampleRate:[engine sampleRate]];
    [_turnTableView setRingBuffer:[_pipeline ring]];
}

- (IBAction)dryVolumeChanged:(id)sender {
    [_pipeline setDryVolume:_sliderDry.floatValue];
}

- (IBAction)startStopButtonClicked:(id)sender {
    if (_btnStop.state == NSControlStateValueOn){
        if (_tableStopTimer){
            [_tableStopTimer invalidate];
            _tableStopTimer = nil;
        }

        [_pipeline startPlayback];
        [_btnStop setTitle:@"[S]top"];
    }else{
        [_pipeline beginStop];
        _tableStopTimer = [NSTimer scheduledTimerWithTimeInterval:0.01 target:self selector:@selector(tableStopTimer:) userInfo:nil repeats:YES];
        [_btnStop setTitle:@"[S]tart"];
    }
}

- (void)tableStopTimer:(NSTimer *)t {
    if ([_pipeline tickDeceleration]){
        [_tableStopTimer invalidate];
        _tableStopTimer = nil;
    }
}

-(void)turnTableSpeedRateChanged{
    BOOL resumed = [_pipeline applyScratchSpeedRate:[_turnTableView speedRate]
                                       isScratching:[_turnTableView isScratching]];
    if (resumed){
        [_turnTableView setSpeedRate:1.0];
    }
}


-(void)terminate{
    [_ae shutdown];
}
@end
