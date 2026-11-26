//
//  AMEControlPropertiesViewController.h
//  Redesigned on-screen control editor panel. Replaces the old hand-laid
//  scroll view (CCMenuViewController) with a Settings-style list that sits
//  beside the control and applies changes live.
//

#import <UIKit/UIKit.h>
#import "customcontrols/ControlButton.h"

NS_ASSUME_NONNULL_BEGIN

/// Friendly name for a key code (special buttons, Minecraft actions, raw keys).
NSString *AMEControlKeyName(int keycode);

@interface AMEControlPropertiesViewController : UIViewController
- (instancetype)initWithButton:(ControlButton *)button;
/// YES puts the panel on the left edge (used when the control is on the right).
@property(nonatomic) BOOL panelOnLeft;
/// Called after Done (changed = only the keys that differ) or Cancel (changed is empty).
@property(nonatomic, copy, nullable) void (^onFinish)(NSMutableDictionary *oldProperties, NSMutableDictionary *changed);
@end

NS_ASSUME_NONNULL_END
