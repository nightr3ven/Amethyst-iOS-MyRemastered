#import "ControllerInput.h"
#import "../LauncherPreferences.h"
#import "../PLProfiles.h"
#import "../SurfaceViewController.h"
#import "../utils.h"

#include "../glfw_keycodes.h"

// Left thumbstick directions
#define DIRECTION_EAST 0
#define DIRECTION_NORTH_EAST 1
//#define DIRECTION_NORTH 2
#define DIRECTION_NORTH_WEST 3
//#define DIRECTION_WEST 4
#define DIRECTION_SOUTH_WEST 5
//#define DIRECTION_SOUTH 6
#define DIRECTION_SOUTH_EAST 7
#define MOUSE_MAX_ACCELERATION 2

CFAbsoluteTime lastFrameTime;
CGFloat lastXValue; // lastHorizontalValue (right stick)
CGFloat lastYValue; // lastVerticalValue (right stick)
// The left stick moves the cursor only in menus. It has its own values so the
// two sticks don't overwrite each other (that made the menu cursor jitter).
static CGFloat leftXValue, leftYValue;

// Radial dead zone on top of GameController's own: cheap pads drift a little
// past it, which nudged the cursor/camera every frame. Rescales the rest so
// small deliberate motion still works.
static void AMEApplyDeadZone(CGFloat *x, CGFloat *y) {
    const CGFloat dz = 0.12;
    CGFloat m = sqrt((*x) * (*x) + (*y) * (*y));
    if (m < dz) { *x = 0; *y = 0; return; }
    CGFloat scaled = MIN(1.0, (m - dz) / (1.0 - dz));
    *x = *x / m * scaled;
    *y = *y / m * scaled;
}

@implementation ControllerInput

NSMutableDictionary *gameMap, *menuMap;
BOOL leftShiftHeld;

+ (void)initKeycodeTable {
    if (gameMap && menuMap) {
        return;
    }
    
    NSString *controlFile = [PLProfiles resolveKeyForCurrentProfile:@"defaultGamepadCtrl"];
    NSString *gamepadPath = [NSString stringWithFormat:@"%s/controlmap/gamepads/%@", getenv("POJAV_HOME"), controlFile];
    NSMutableDictionary *gamepadJSON = parseJSONFromFile(gamepadPath);
    
    gameMap = gamepadJSON[@"mGameMappingList"];
    menuMap = gamepadJSON[@"mMenuMappingList"];
}

+ (void)sendKeyEvent:(int)controllerKeycode pressed:(BOOL)pressed {
    // Unmapped buttons (e.g. Home) must do nothing, not send whatever was on the stack.
    int keycode = GLFW_KEY_UNKNOWN;
    __block NSMutableDictionary *mapping;
    if (isGrabbing) {
        mapping = gameMap;
    } else {
        mapping = menuMap;
    }
    
    for (NSMutableDictionary *buttonDict in mapping) {
        if(controllerKeycode == [buttonDict[@"gamepad_button"] intValue]) {
            keycode = [buttonDict[@"keycode"] intValue];
        }
    }

    switch (keycode) {
        case GLFW_KEY_UNKNOWN:
            // Do nothing
            break;
        case -GLFW_KEY_LEFT_SHIFT:
            if (!pressed) {
                leftShiftHeld = !leftShiftHeld;
                CallbackBridge_nativeSendKey(GLFW_KEY_LEFT_SHIFT, 0, leftShiftHeld, 0);
            }
            break;
        case SPECIALBTN_MOUSEPRI:
            CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_LEFT, pressed, 0);
            break;
        case SPECIALBTN_MOUSEMID:
            CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_MIDDLE, pressed, 0);
            break;
        case SPECIALBTN_MOUSESEC:
            CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_RIGHT, pressed, 0);
            break;
        case SPECIALBTN_SCROLLUP:
            CallbackBridge_nativeSendScroll(0, pressed ? 1 : 0);
            break;
        case SPECIALBTN_SCROLLDOWN:
            CallbackBridge_nativeSendScroll(0, pressed ? -1 : 0);
            break;
        default:
            if (keycode == GLFW_KEY_LEFT_SHIFT) {
                leftShiftHeld = pressed;
            }
            CallbackBridge_nativeSendKey(keycode, 0, pressed, 0);
            break;
    }
}

+ (void)registerControllerCallbacks:(GCController *)controller {
    GCExtendedGamepad *gamepad = controller.extendedGamepad;

    gamepad.leftShoulder.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_LEFT_BUMPER pressed:pressed];
    };
    gamepad.rightShoulder.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_RIGHT_BUMPER pressed:pressed];
    };

    gamepad.leftTrigger.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_LEFT_TRIGGER pressed:pressed];
    };
    gamepad.rightTrigger.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_RIGHT_TRIGGER pressed:pressed];
    };
    gamepad.buttonOptions.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_BACK pressed:pressed];
    };
    gamepad.buttonMenu.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_START pressed:pressed];
    };
    gamepad.buttonHome.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_GUIDE pressed:pressed];
    };

    gamepad.buttonA.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_A pressed:pressed];
    };
    gamepad.buttonB.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_B pressed:pressed];
    };
    gamepad.buttonX.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_X pressed:pressed];
    };
    gamepad.buttonY.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_Y pressed:pressed];
    };

    gamepad.dpad.up.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_DPAD_UP pressed:pressed];
    };
    gamepad.dpad.down.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_DPAD_DOWN pressed:pressed];
    };
    gamepad.dpad.left.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_DPAD_LEFT pressed:pressed];
    };
    gamepad.dpad.right.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_DPAD_RIGHT pressed:pressed];
    };

    gamepad.leftThumbstick.valueChangedHandler = ^(GCControllerDirectionPad * _Nonnull dpad, float xValue, float yValue) {
        if (!isGrabbing) {
            // Menus: the left stick moves the cursor.
            leftXValue = xValue;
            leftYValue = yValue;
            AMEApplyDeadZone(&leftXValue, &leftYValue);
            return;
        }
        leftXValue = 0; leftYValue = 0;

        static char lastLThumbDirection = -2;
        char direction = -1;
        // 同 ControlJoystick：测"偏离中心"用或而非与。手柄更常见——GCController
        // 在死区内把轴直接 snap 到 0，前推带轻微侧漂也会被误判为静止。
        if (xValue != 0 || yValue != 0) {
            CGFloat degree = atan2f(yValue, xValue) * (180.0 / M_PI);
            if (degree < 0) {
                degree += 360;
            }
            direction = (int)((degree+22.5)/45.0) % 8;
        }
        if (lastLThumbDirection == direction) {
            return;
        }

        // Update WASD states
        CallbackBridge_nativeSendKey(GLFW_KEY_W, 0,
            direction >= DIRECTION_NORTH_EAST &&
            direction <= DIRECTION_NORTH_WEST, 0);
        CallbackBridge_nativeSendKey(GLFW_KEY_A, 0,
            direction >= DIRECTION_NORTH_WEST &&
            direction <= DIRECTION_SOUTH_WEST, 0);
        CallbackBridge_nativeSendKey(GLFW_KEY_S, 0,
            direction >= DIRECTION_SOUTH_WEST &&
            direction <= DIRECTION_SOUTH_EAST, 0);
        CallbackBridge_nativeSendKey(GLFW_KEY_D, 0,
            direction == DIRECTION_SOUTH_EAST ||
            direction == DIRECTION_EAST ||
            direction == DIRECTION_NORTH_EAST, 0);

        lastLThumbDirection = direction;
    };
    gamepad.rightThumbstick.valueChangedHandler = ^(GCControllerDirectionPad * _Nonnull dpad, float xValue, float yValue) {
        // Camera in game; in menus it moves the cursor like the left stick.
        lastXValue = xValue;
        lastYValue = yValue;
        AMEApplyDeadZone(&lastXValue, &lastYValue);
    };
    gamepad.leftThumbstickButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_LEFT_THUMB pressed:pressed];
    };
    gamepad.rightThumbstickButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_RIGHT_THUMB pressed:pressed];
    };
}

/**
 * Send the new mouse position, computing the delta
 */
+ (void)tick {
    // There isn't a convenient way to get ns, use ms at this point
    CGFloat frameTime = CACurrentMediaTime();
    // GameController automatically performs deadzone calculations
    // so we just take the raw input
    // In menus either stick moves the cursor; use whichever is pushed further.
    CGFloat sx = lastXValue, sy = lastYValue;
    if (!isGrabbing && (leftXValue * leftXValue + leftYValue * leftYValue) > (sx * sx + sy * sy)) {
        sx = leftXValue; sy = leftYValue;
    }
    if (lastFrameTime != 0 && (sx != 0 || sy != 0)) {
        CGFloat acceleration = pow(MathUtils_dist(0, 0, sx, sy), MOUSE_MAX_ACCELERATION); // magnitude
        if (acceleration > 1) acceleration = 1;

        // Compute delta since last tick time
        CGFloat deltaX = sx * acceleration * 18;
        CGFloat deltaY = -sy * acceleration * 18;
        CGFloat deltaTimeScale = (frameTime - lastFrameTime) / (1.0/60.0); // Scale of 1 = 60Hz
        deltaX *= deltaTimeScale;
        deltaY *= deltaTimeScale;

        SurfaceViewController *vc = [SurfaceViewController currentInstance];
        if (vc) {
            [vc sendTouchPoint:CGPointMake(deltaX, deltaY) withEvent:ACTION_MOVE_MOTION];
        }
    }
    lastFrameTime = frameTime;
}

+ (void)unregisterControllerCallbacks:(GCController *)controller {
    GCExtendedGamepad *gamepad = controller.extendedGamepad;
    gamepad.leftShoulder.pressedChangedHandler = nil;
    gamepad.rightShoulder.pressedChangedHandler = nil;
    gamepad.leftTrigger.pressedChangedHandler = nil;
    gamepad.rightTrigger.pressedChangedHandler = nil;
    gamepad.buttonOptions.pressedChangedHandler = nil;
    gamepad.buttonMenu.pressedChangedHandler = nil;
    gamepad.buttonHome.pressedChangedHandler = nil;
    gamepad.buttonA.pressedChangedHandler = nil;
    gamepad.buttonB.pressedChangedHandler = nil;
    gamepad.buttonX.pressedChangedHandler = nil;
    gamepad.buttonY.pressedChangedHandler = nil;
    gamepad.dpad.up.pressedChangedHandler = nil;
    gamepad.dpad.down.pressedChangedHandler = nil;
    gamepad.dpad.left.pressedChangedHandler = nil;
    gamepad.dpad.right.pressedChangedHandler = nil;
    gamepad.leftThumbstick.valueChangedHandler = nil;
    gamepad.rightThumbstick.valueChangedHandler = nil;
    gamepad.leftThumbstickButton.pressedChangedHandler = nil;
    gamepad.rightThumbstickButton.pressedChangedHandler = nil;
}

@end
