//
//  RingBuffer.h
//  MyPlaythrough
//
//  Created by kyab on 2017/05/16.
//  Copyright © 2017年 kyab. All rights reserved.
//

#import <Foundation/Foundation.h>

#define RING_SIZE_SAMPLE 44100*10

@interface RingBuffer : NSObject
{
    float *_leftBuf;
    float *_rightBuf;
    
    UInt32 _bufSize;    //actual size
    
    UInt32 _recordFrame;
    UInt32 _playFrame;
    
    
    UInt32 _minOffsetFrame;
}


-(float *)writePtrLeft;
-(float *)writePtrRight;
-(void)advanceWritePtrSample:(SInt32)sample;
-(float *)readPtrLeft;
-(float *)readPtrRight;
-(float *)startPtrLeft;
-(float *)startPtrRight;
-(UInt32)advanceReadPtrSample:(SInt32)sample;
-(void)moveReadPtrToSample:(UInt32)sample;
-(UInt32)readPtrDistanceFrom:(SInt32)sample;

-(void)resetBuffer;
-(void)follow;

-(Boolean)isShortage;
//-(void)dumpStatus;



-(UInt32)frames;
-(UInt32)bufSize;

-(UInt32)recordFrame;
-(UInt32)playFrame;


@end
