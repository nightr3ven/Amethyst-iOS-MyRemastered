//
//  AMEKeyboardAccessoryView.h
//  Toolbar shown above the on-screen keyboard while in game.
//
//  Gives the soft keyboard the keys a phone keyboard lacks (Esc, Tab, /, arrows)
//  and, most importantly, an always-visible button to put the keyboard away.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AMEKeyboardAccessoryView : UIInputView

/// Called with a GLFW key code when a key button is tapped (press + release).
@property(nonatomic, copy, nullable) void (^onKey)(int glfwKey);
/// Called with a character when a character button is tapped (e.g. "/").
@property(nonatomic, copy, nullable) void (^onCharacter)(unichar character);
/// Called when the user taps the hide-keyboard button.
@property(nonatomic, copy, nullable) void (^onDismiss)(void);

+ (instancetype)accessoryView;

@end

NS_ASSUME_NONNULL_END
