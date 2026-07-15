//
//  PipelineTestRunner.m
//  Scratch NowTests
//

#import "PipelineTestRunner.h"
#import <math.h>

@interface PipelineScheduledEvent : NSObject
@property (nonatomic) SInt64 frame;
@property (nonatomic) BOOL isStop;
@property (nonatomic, copy, nullable) void (^action)(PipelineTestRunner *runner);
@end

@implementation PipelineScheduledEvent
@end

@implementation PipelineTestRunner {
    double _sampleRate;
    UInt32 _blockFrames;
    NSMutableArray<PipelineScheduledEvent *> *_events;
}

- (instancetype)initWithSampleRate:(double)sampleRate blockFrames:(UInt32)blockFrames {
    self = [super init];
    if (self) {
        _sampleRate = sampleRate;
        _blockFrames = blockFrames > 0 ? blockFrames : 512;
        _events = [NSMutableArray array];
        _pipeline = [[ScratchPipeline alloc] initWithSampleRate:sampleRate];
        _input = [[SyntheticInputSource alloc] initWithSampleRate:sampleRate];
        _output = [[CaptureOutputSink alloc] initWithSampleRate:sampleRate];
        _input.inputConsumer = _pipeline;
        _output.outputRenderer = _pipeline;
    }
    return self;
}

- (double)sampleRate {
    return _sampleRate;
}

- (void)scheduleAtSeconds:(double)seconds action:(void (^)(PipelineTestRunner *runner))action {
    PipelineScheduledEvent *event = [[PipelineScheduledEvent alloc] init];
    event.frame = (SInt64)llround(seconds * _sampleRate);
    event.isStop = NO;
    event.action = action;
    [_events addObject:event];
}

- (void)scheduleStopAtSeconds:(double)seconds {
    PipelineScheduledEvent *event = [[PipelineScheduledEvent alloc] init];
    event.frame = (SInt64)llround(seconds * _sampleRate);
    event.isStop = YES;
    [_events addObject:event];
}

- (void)runForSeconds:(double)seconds {
    [_input startCapture];
    [_output startPlayback];

    // Prime the ring with tone so the read head has valid data once we follow it.
    SInt64 warmupFrames = (SInt64)llround(0.05 * _sampleRate);
    if (warmupFrames < _blockFrames) {
        warmupFrames = _blockFrames;
    }
    for (SInt64 f = 0; f < warmupFrames; f += _blockFrames) {
        [_input produceFrames:_blockFrames];
    }

    // Engage live playback (follow the write head).
    [_pipeline startPlayback];

    NSArray<PipelineScheduledEvent *> *sortedEvents =
        [_events sortedArrayUsingComparator:^NSComparisonResult(PipelineScheduledEvent *a, PipelineScheduledEvent *b) {
            if (a.frame < b.frame) return NSOrderedAscending;
            if (a.frame > b.frame) return NSOrderedDescending;
            return NSOrderedSame;
        }];

    SInt64 totalFrames = (SInt64)llround(seconds * _sampleRate);
    SInt64 tickInterval = (SInt64)llround(0.01 * _sampleRate);
    if (tickInterval < 1) {
        tickInterval = 1;
    }

    BOOL decelerating = NO;
    BOOL stopped = NO;
    SInt64 framesUntilTick = 0;
    NSUInteger nextEventIndex = 0;
    SInt64 currentFrame = 0;

    while (currentFrame < totalFrames) {
        // Apply any events whose time has arrived.
        while (nextEventIndex < sortedEvents.count &&
               sortedEvents[nextEventIndex].frame <= currentFrame) {
            PipelineScheduledEvent *event = sortedEvents[nextEventIndex];
            if (event.isStop) {
                [_pipeline beginStop];
                decelerating = YES;
                framesUntilTick = tickInterval;
            } else if (event.action) {
                event.action(self);
            }
            nextEventIndex++;
        }

        // Deterministically fire the 10ms deceleration ticks for this block.
        if (decelerating && !stopped) {
            framesUntilTick -= (SInt64)_blockFrames;
            while (framesUntilTick <= 0 && !stopped) {
                stopped = [_pipeline tickDeceleration];
                framesUntilTick += tickInterval;
            }
        }

        [_input produceFrames:_blockFrames];
        [_output pullFrames:_blockFrames];
        currentFrame += _blockFrames;
    }
}

@end
