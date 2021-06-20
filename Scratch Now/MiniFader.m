//
//  MiniFader.m
//  Going Zero
//
//  Created by kyab on 2021/06/01.
//  Copyright © 2021 kyab. All rights reserved.
//

#import "MiniFader.h"

@implementation MiniFaderIn

-(id)init{
    self = [super init];
    
    _count = FADE_SAMPLE_NUM;
    return self;
}

-(void)startFadeIn{
//    NSLog(@"fade in start");
    _count = 0;
}

-(void)processLeft:(float *)leftBuf right:(float *)rightBuf samples:(UInt32)numSamples{
    for (int i = 0; i < numSamples; i++){
        if (_count < FADE_SAMPLE_NUM){
            float rate = _count / (float)FADE_SAMPLE_NUM;
            leftBuf[i] *= rate;
            rightBuf[i] *= rate;

            
//            NSLog(@"fade in count = %d, left = %f", _count, leftBuf[i]);
            _count++;
        }
    }
    
}
@end

@implementation MiniFaderOut

-(id)init{
    self = [super init];
    
    _count = 0;
    return self;
}

-(void)startFadeOut{
//    NSLog(@"fade out start");
    _count = FADE_SAMPLE_NUM;
}

-(void)processLeft:(float *)leftBuf right:(float *)rightBuf samples:(UInt32)numSamples{
    for (int i = 0; i < numSamples; i++){
        if (0 < _count){
            float rate = _count / (float)FADE_SAMPLE_NUM;
            leftBuf[i] *= rate;
            rightBuf[i] *= rate;
            
            //NSLog(@"fade out count = %d, left = %f", _count, leftBuf[i]);
            _count--;
        }

    }
    
}

@end
