//
//  ConstantPitchStopTests.m
//  Scratch NowTests
//
//  Scenario: feed a constant-pitch tone into the pipeline, trigger a turntable Stop
//  via simulated control, and verify from the captured output that the pitch glides
//  down and the sound ultimately stops (AC energy collapses to ~0).
//

#import <XCTest/XCTest.h>
#import "PipelineTestRunner.h"
#import "WaveformAnalyzer.h"

@interface ConstantPitchStopTests : XCTestCase
@end

@implementation ConstantPitchStopTests {
    double _sampleRate;
    double _inputFrequency;
}

- (void)setUp {
    _sampleRate = 48000.0;
    _inputFrequency = 440.0;
}

// Window helpers over the captured left channel.
- (double)pitchOfCapture:(CaptureOutputSink *)output
              fromSeconds:(double)startSec
                toSeconds:(double)endSec {
    NSUInteger offset = (NSUInteger)llround(startSec * _sampleRate);
    NSUInteger end = (NSUInteger)llround(endSec * _sampleRate);
    XCTAssertLessThanOrEqual(end, output.frameCount, @"window exceeds captured audio");
    return [WaveformAnalyzer estimatePitchOfSamples:output.leftChannel
                                             offset:offset
                                             length:(end - offset)
                                         sampleRate:_sampleRate];
}

- (double)acRMSOfCapture:(CaptureOutputSink *)output
             fromSeconds:(double)startSec
               toSeconds:(double)endSec {
    NSUInteger offset = (NSUInteger)llround(startSec * _sampleRate);
    NSUInteger end = (NSUInteger)llround(endSec * _sampleRate);
    XCTAssertLessThanOrEqual(end, output.frameCount, @"window exceeds captured audio");
    return [WaveformAnalyzer acRMSOfSamples:output.leftChannel
                                     offset:offset
                                     length:(end - offset)];
}

- (void)testConstantPitchThenStopGlidesDownToSilence {
    PipelineTestRunner *runner = [[PipelineTestRunner alloc] initWithSampleRate:_sampleRate
                                                                    blockFrames:512];
    runner.input.frequency = _inputFrequency;
    runner.input.amplitude = 0.5;

    // Trigger the turntable Stop at t = 1.0s; run for 2.5s total.
    [runner scheduleStopAtSeconds:1.0];
    [runner runForSeconds:2.5];

    XCTAssertGreaterThan(runner.output.frameCount, (NSUInteger)(2.4 * _sampleRate),
                         @"expected a full capture");

    // 1) Baseline: before Stop the output reproduces the input pitch with real energy.
    double baselinePitch = [self pitchOfCapture:runner.output fromSeconds:0.3 toSeconds:0.9];
    double baselineRMS = [self acRMSOfCapture:runner.output fromSeconds:0.3 toSeconds:0.9];
    XCTAssertGreaterThan(baselineRMS, 0.05, @"baseline should carry audible energy");
    XCTAssertEqualWithAccuracy(baselinePitch, _inputFrequency, 30.0,
                               @"baseline pitch should match the input tone");

    // 2) Deceleration: pitch drops monotonically after Stop.
    double earlyDecelPitch = [self pitchOfCapture:runner.output fromSeconds:1.1 toSeconds:1.2];
    double lateDecelPitch = [self pitchOfCapture:runner.output fromSeconds:1.3 toSeconds:1.4];
    XCTAssertLessThan(earlyDecelPitch, baselinePitch,
                      @"pitch should fall once the platter starts stopping");
    XCTAssertLessThan(lateDecelPitch, earlyDecelPitch,
                      @"pitch should keep falling as the platter slows");

    // 3) Stopped: the tail collapses to near silence (frozen sample -> ~0 AC energy).
    double finalRMS = [self acRMSOfCapture:runner.output fromSeconds:2.2 toSeconds:2.5];
    XCTAssertLessThan(finalRMS, baselineRMS * 0.02,
                      @"the sound should have essentially stopped");
    XCTAssertLessThan(finalRMS, 1e-3, @"the tail should be effectively silent");

    double finalPitch = [self pitchOfCapture:runner.output fromSeconds:2.2 toSeconds:2.5];
    XCTAssertEqualWithAccuracy(finalPitch, 0.0, 1.0,
                               @"a stopped platter has no pitch");
}

@end
