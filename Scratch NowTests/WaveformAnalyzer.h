//
//  WaveformAnalyzer.h
//  Scratch NowTests
//
//  Small analysis helpers used to judge test outcomes from captured PCM:
//  windowed AC RMS (energy after removing DC) and zero-crossing pitch estimation.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WaveformAnalyzer : NSObject

// RMS of the samples after subtracting their mean (removes DC offset so a frozen
// constant signal reports ~0 energy).
+ (double)acRMSOfSamples:(const float *)samples
                   offset:(NSUInteger)offset
                   length:(NSUInteger)length;

// Estimated fundamental frequency (Hz) via mean zero-crossing rate of the AC signal.
// Returns 0 when the signal has effectively no oscillation.
+ (double)estimatePitchOfSamples:(const float *)samples
                          offset:(NSUInteger)offset
                          length:(NSUInteger)length
                      sampleRate:(double)sampleRate;

@end

NS_ASSUME_NONNULL_END
