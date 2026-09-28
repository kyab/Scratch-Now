//
//  TurnTableController.m
//  Scratch Now
//

#import "TurnTableController.h"

@implementation TurnTableController

-(void)viewDidLoad{
    [super viewDidLoad];
    [_platterView setDelegate:self];
}

-(void)setTurnTable:(TurnTable *)turnTable{
    [self loadViewIfNeeded];
    _turnTable = turnTable;
    [_turnTable setAutoFollow:(_chkAutoFollow.state == NSControlStateValueOn)];
    [_platterView setTurnTable:_turnTable];
}

#pragma mark - PlatterViewDelegate

-(void)platterViewScratchBegan:(PlatterView *)platterView{
    [_turnTable beginScratch];
}

-(void)platterView:(PlatterView *)platterView scratchSpeedChanged:(double)speedRate{
    [_turnTable updateScratchSpeed:speedRate];
}

-(void)platterView:(PlatterView *)platterView scratchEndedWithReleaseSpeed:(double)speedRate{
    [_turnTable endScratchWithReleaseSpeed:speedRate];
}

#pragma mark - Actions

- (IBAction)dryVolumeChanged:(id)sender {
    [_turnTable setDryVolume:_sliderDry.floatValue];
}

- (IBAction)autoFollowChanged:(id)sender {
    [_turnTable setAutoFollow:(_chkAutoFollow.state == NSControlStateValueOn)];
}

- (IBAction)followButtonClicked:(id)sender {
    [_turnTable follow];
}

- (IBAction)startStopButtonClicked:(id)sender {
    if (_btnStop.state == NSControlStateValueOn){ //"Start"
        [_turnTable start];
        [_btnStop setTitle:@"[S]top"];
    }else{      //"Stop"
        [_turnTable stop];
        [_btnStop setTitle:@"[S]tart"];
    }
}

@end
