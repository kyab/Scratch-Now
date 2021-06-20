//
//  AppDelegate.h
//  Scratch Now
//
//  Created by kyab on 2021/06/19.
//

#import <Cocoa/Cocoa.h>
#import "AppController.h"


@interface AppDelegate : NSObject <NSApplicationDelegate>{
    
    __weak IBOutlet AppController *_controller;
}


@end

