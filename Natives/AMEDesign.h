//
//  AMEDesign.h
//  Shared look for the redesigned launcher: one accent colour, system text
//  styles, standard grouped lists, and a few reusable pieces.
//
//  Rule of thumb for new UI: use stock UIKit components (inset-grouped lists,
//  system buttons, SF Symbols, dynamic colours) and only these helpers on top.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// localize() returns the key itself when a translation is missing; this returns
/// the English fallback instead, so new screens never show raw keys.
NSString *AMEL(NSString *key, NSString *english);

typedef NS_ENUM(NSInteger, AMEButtonStyle) {
    AMEButtonStylePrimary,    // filled accent, for the one main action on a screen
    AMEButtonStyleSecondary,  // tinted / gray, for supporting actions
};

@interface AMEDesign : NSObject

/// Launcher accent (a Minecraft-ish green that reads well in light and dark).
@property(class, nonatomic, readonly) UIColor *accentColor;

/// Standard corner radius for cards.
@property(class, nonatomic, readonly) CGFloat cardCornerRadius;

/// A system-style button that falls back gracefully on iOS 14.
+ (UIButton *)buttonWithTitle:(nullable NSString *)title
                       symbol:(nullable NSString *)symbol
                        style:(AMEButtonStyle)style;

/// Updates a button made by +buttonWithTitle:symbol:style:.
+ (void)setTitle:(nullable NSString *)title ofButton:(UIButton *)button;

/// Rounded-square coloured icon like the Settings app (29pt).
+ (UIImage *)iconTileWithSymbol:(NSString *)symbol color:(UIColor *)color;

/// Applies continuous corners + card background to a view.
+ (void)styleCard:(UIView *)view;

@end

NS_ASSUME_NONNULL_END
