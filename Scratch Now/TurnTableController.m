//
//  TurnTableController.m
//  Scratch Now
//

#import "TurnTableController.h"

static NSString * const kAutoFollowDefaultsKey = @"autoFollow";

@implementation TurnTableController

-(void)viewDidLoad{
    [super viewDidLoad];
    [_platterView setDelegate:self];

    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        kAutoFollowDefaultsKey: @YES
    }];
    BOOL autoFollow = [[NSUserDefaults standardUserDefaults] boolForKey:kAutoFollowDefaultsKey];
    [_chkAutoFollow setState:autoFollow ? NSControlStateValueOn : NSControlStateValueOff];
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
    BOOL autoFollow = (_chkAutoFollow.state == NSControlStateValueOn);
    [_turnTable setAutoFollow:autoFollow];
    [[NSUserDefaults standardUserDefaults] setBool:autoFollow forKey:kAutoFollowDefaultsKey];
}

- (IBAction)followButtonClicked:(id)sender {
    [_turnTable follow];
}

- (IBAction)startStopButtonClicked:(id)sender {
    if (_btnStop.state == NSControlStateValueOn){ //"Start"
        [_turnTable start];
        [_btnStop setTitle:@"Stop\n[Space]"];
    }else{      //"Stop"
        [_turnTable stop];
        [_btnStop setTitle:@"Start\n[Space]"];
    }
}

@end
