//
//  RingBuffer.h
//
//  Created by kyab on 2017/05/16.
//  Copyright © 2017年 kyab. All rights reserved.
//

#import <Foundation/Foundation.h>

#define RING_SIZE_SECONDS 30

@interface RingBuffer : NSObject
{
    float *_leftBuf;
    float *_rightBuf;
    
    UInt32 _bufSize;    //actual size
    
    double _sampleRate;
    
    UInt32 _recordFrame;
    UInt32 _playFrame;
    UInt32 _dryFrame;
    
    UInt32 _minOffsetFrame;
}

-(id)initWithSampleRate:(double)sampleRate;
-(double)sampleRate;


-(float *)writePtrLeft;
-(float *)writePtrRight;
-(void)advanceWritePtrSample:(SInt32)sample;
-(float *)readPtrLeft;
-(float *)readPtrRight;
-(UInt32)advanceReadPtrSample:(SInt32)sample;
-(float *)dryPtrLeft;
-(float *)dryPtrRight;
-(UInt32)advanceDryPtrSample:(SInt32)sample;

-(float *)startPtrLeft;
-(float *)startPtrRight;


-(void)follow;

-(Boolean)isShortage;

-(UInt32)frames;
//-(UInt32)bufSize;

-(UInt32)recordFrame;
-(UInt32)playFrame;

-(UInt32)readWriteOffset;

-(void)setMinOffset:(UInt32) offset;

-(void)reset;


@end
