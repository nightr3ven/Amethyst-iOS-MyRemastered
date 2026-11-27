#import <GameController/GameController.h>
#import <UIKit/UIKit.h>

@interface ControllerInput : NSObject

+ (void)initKeycodeTable;
+ (void)registerControllerCallbacks:(GCController *)controller;
+ (void)unregisterControllerCallbacks:(GCController *)controller;
+ (void)tick;

@end

/// Per-instance "Controller mod" switch: pass the controller straight to the game
/// (for MidnightControls) instead of Air mapping it to keys and mouse.
void AMEControllerSetModEnabled(BOOL enabled);
