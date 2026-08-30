//
//  AppDelegate.m
//  Scratch Now
//
//  Created by kyab on 2021/06/19.
//

#import "AppDelegate.h"

@interface AppDelegate ()

@property (strong) IBOutlet NSWindow *window;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    // Insert code here to initialize your application
}

- (IBAction)showPrivacyPolicy:(id)sender {
    NSURL *url = [NSURL URLWithString:@"https://github.com/kyab/Scratch-Now/blob/main/PRIVACY.md"];
    if (url) {
        [[NSWorkspace sharedWorkspace] openURL:url];
    }
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    [_controller terminate];
    return NSTerminateLater;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
    return YES;
}

@end
