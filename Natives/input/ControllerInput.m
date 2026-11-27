#import "ControllerInput.h"
#import "../LauncherPreferences.h"
#import "../PLProfiles.h"
#import "../SurfaceViewController.h"
#import "../utils.h"

#include "../glfw_keycodes.h"
#include <jni.h>
#include "../environ.h"
#include <os/lock.h>

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

// ---------------------------------------------------------------------------
// Direct gamepad input for controller mods (MidnightControls, Controlify's GLFW
// driver). LWJGL's glfwGetGamepadState / glfwJoystickPresent on controller 0
// are answered from the connected GCController. While a mod is polling them,
// Air stops turning the controller into keys, mouse buttons and cursor motion,
// so every press isn't handled twice. Vanilla never polls, so it keeps Air's
// own mapping.
// ---------------------------------------------------------------------------
static GCExtendedGamepad *g_ameDirectPad;
static os_unfair_lock g_ameDirectPadLock = OS_UNFAIR_LOCK_INIT;
static _Atomic double g_ameDirectPolledAt;
// Per-instance switch (instance setting "Controller mod"): only then is the
// controller reported to the game at all. Read when the game launches.
static BOOL g_ameControllerModEnabled;

void AMEControllerSetModEnabled(BOOL enabled) {
    g_ameControllerModEnabled = enabled;
    g_ameDirectPolledAt = 0;
    NSLog(@"[Controller] controller mod %@ for this instance", enabled ? @"ON (pass-through)" : @"off (Air's built-in mapping)");
}

static GCExtendedGamepad *AMEDirectPad(void) {
    if (!g_ameControllerModEnabled) return nil;
    os_unfair_lock_lock(&g_ameDirectPadLock);
    GCExtendedGamepad *pad = g_ameDirectPad;
    os_unfair_lock_unlock(&g_ameDirectPadLock);
    return pad;
}

static void AMESetDirectPad(GCExtendedGamepad *pad) {
    os_unfair_lock_lock(&g_ameDirectPadLock);
    g_ameDirectPad = pad;
    os_unfair_lock_unlock(&g_ameDirectPadLock);
}

// A mod read the gamepad in the last second.
static BOOL AMEGamepadDirect(void) {
    if (!g_ameControllerModEnabled) return NO;
    double t = g_ameDirectPolledAt;
    return t > 0 && CACurrentMediaTime() - t < 1.0;
}

JNIEXPORT jboolean JNICALL
Java_org_lwjgl_glfw_GLFW_nglfwJoystickPresent(JNIEnv *env, jclass clazz, jint jid) {
    return (jid == 0 && AMEDirectPad() != nil) ? JNI_TRUE : JNI_FALSE;
}

// Fills a GLFWgamepadstate: unsigned char buttons[15], then float axes[6] at offset 16.
JNIEXPORT jboolean JNICALL
Java_org_lwjgl_glfw_GLFW_nglfwGetGamepadState(JNIEnv *env, jclass clazz, jint jid, jlong statePtr) {
    GCExtendedGamepad *p = jid == 0 ? AMEDirectPad() : nil;
    if (p == nil || statePtr == 0) return JNI_FALSE;
    unsigned char *buttons = (unsigned char *)(intptr_t)statePtr;
    float *axes = (float *)(buttons + 16);
    GCControllerButtonInput *b[15] = {
        p.buttonA, p.buttonB, p.buttonX, p.buttonY,
        p.leftShoulder, p.rightShoulder,
        p.buttonOptions, p.buttonMenu, p.buttonHome,
        p.leftThumbstickButton, p.rightThumbstickButton,
        p.dpad.up, p.dpad.right, p.dpad.down, p.dpad.left,
    };
    for (int i = 0; i < 15; i++) buttons[i] = (b[i] != nil && b[i].isPressed) ? 1 : 0;
    // GLFW: stick Y is +1 pointing down; triggers run -1 (released) to +1.
    axes[0] = p.leftThumbstick.xAxis.value;
    axes[1] = -p.leftThumbstick.yAxis.value;
    axes[2] = p.rightThumbstick.xAxis.value;
    axes[3] = -p.rightThumbstick.yAxis.value;
    axes[4] = p.leftTrigger.value * 2.0f - 1.0f;
    axes[5] = p.rightTrigger.value * 2.0f - 1.0f;
    static BOOL logged = NO;
    if (!logged) {
        logged = YES;
        NSLog(@"[Controller] a mod is reading the gamepad directly; Air's own controller mapping is paused while it does");
    }
    g_ameDirectPolledAt = CACurrentMediaTime();
    return JNI_TRUE;
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
    if (AMEGamepadDirect()) return;  // a controller mod handles the pad itself
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
    if (gamepad) AMESetDirectPad(gamepad);

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
        if (AMEGamepadDirect()) {
            xValue = 0; yValue = 0;  // release WASD / stop the cursor; the mod moves instead
        }
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
        if (AMEGamepadDirect()) { xValue = 0; yValue = 0; }
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
    if (AMEGamepadDirect()) {
        lastXValue = lastYValue = leftXValue = leftYValue = 0;
        lastFrameTime = frameTime;
        // The mod moves the game cursor (glfwSetCursorPos); keep Air's on-screen
        // pointer on top of it. Game px = points x screenScale x resolutionScale.
        SurfaceViewController *vc = [SurfaceViewController currentInstance];
        CGFloat k = vc.screenScale * resolutionScale;
        if (vc && !isGrabbing && k > 0) {
            CGPoint pt = CGPointMake(cursorX / k, cursorY / k);
            if (fabs(pt.x - virtualMouseFrame.origin.x) > 0.25 || fabs(pt.y - virtualMouseFrame.origin.y) > 0.25) {
                virtualMouseFrame.origin = pt;
                vc.mousePointerView.frame = virtualMouseFrame;
            }
        }
        return;
    }
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
    if (gamepad && AMEDirectPad() == gamepad) {
        GCController *other = nil;
        for (GCController *c in GCController.controllers) {
            if (c != controller && c.extendedGamepad) { other = c; break; }
        }
        AMESetDirectPad(other.extendedGamepad);
    }
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
