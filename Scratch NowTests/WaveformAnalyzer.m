//
//  WaveformAnalyzer.m
//  Scratch NowTests
//

#import "WaveformAnalyzer.h"
#import <math.h>

@implementation WaveformAnalyzer

+ (double)meanOfSamples:(const float *)samples offset:(NSUInteger)offset length:(NSUInteger)length {
    if (length == 0) {
        return 0.0;
    }
    double sum = 0.0;
    for (NSUInteger i = 0; i < length; i++) {
        sum += samples[offset + i];
    }
    return sum / (double)length;
}

+ (double)acRMSOfSamples:(const float *)samples offset:(NSUInteger)offset length:(NSUInteger)length {
    if (length == 0) {
        return 0.0;
    }
    double mean = [self meanOfSamples:samples offset:offset length:length];
    double sumSquares = 0.0;
    for (NSUInteger i = 0; i < length; i++) {
        double centered = samples[offset + i] - mean;
        sumSquares += centered * centered;
    }
    return sqrt(sumSquares / (double)length);
}

+ (double)estimatePitchOfSamples:(const float *)samples
                          offset:(NSUInteger)offset
                          length:(NSUInteger)length
                      sampleRate:(double)sampleRate {
    if (length < 2) {
        return 0.0;
    }

    double mean = [self meanOfSamples:samples offset:offset length:length];
    double acRMS = [self acRMSOfSamples:samples offset:offset length:length];
    if (acRMS < 1e-5) {
        // No meaningful oscillation (silence or a frozen constant).
        return 0.0;
    }

    // Hysteresis threshold at a fraction of the signal amplitude to reject noise
    // near the zero line while counting genuine crossings.
    double threshold = acRMS * 0.25;
    NSInteger crossings = 0;
    NSInteger state = 0; // -1 below -threshold, +1 above +threshold, 0 unknown

    for (NSUInteger i = 0; i < length; i++) {
        double v = samples[offset + i] - mean;
        if (v > threshold) {
            if (state < 0) {
                crossings++;
            }
            state = 1;
        } else if (v < -threshold) {
            if (state > 0) {
                crossings++;
            }
            state = -1;
        }
    }

    double durationSeconds = (double)length / sampleRate;
    if (durationSeconds <= 0.0) {
        return 0.0;
    }
    // Two threshold crossings per cycle.
    return ((double)crossings / 2.0) / durationSeconds;
}

@end
