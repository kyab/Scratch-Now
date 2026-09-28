//
//  AppController.h
//  Scratch Now
//
//  Created by kyab on 2021/06/19.
//

#import <Foundation/Foundation.h>
#import <Cocoa/Cocoa.h>
#import "AudioEngine.h"
#import "TurnTable.h"
#import "TurnTableController.h"

NS_ASSUME_NONNULL_BEGIN

#define INPUT_BUFFER_FRAMES 16384

@interface AppController : NSObject{
    AudioEngine *_ae;
    TurnTable *_turnTable;
    TurnTableController *_turnTableController;
    __weak IBOutlet NSView *_turnTableContentView;

    float _inputLeft[INPUT_BUFFER_FRAMES];
    float _inputRight[INPUT_BUFFER_FRAMES];
}

-(void)terminate;


@end

NS_ASSUME_NONNULL_END
