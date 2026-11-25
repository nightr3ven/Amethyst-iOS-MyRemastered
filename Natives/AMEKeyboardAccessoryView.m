//
//  AMEKeyboardAccessoryView.m
//

#import "AMEKeyboardAccessoryView.h"
#include "glfw_keycodes.h"

typedef NS_ENUM(NSInteger, AMEAccessoryKind) {
    AMEAccessoryKindKey,
    AMEAccessoryKindCharacter,
    AMEAccessoryKindDismiss,
};

@implementation AMEKeyboardAccessoryView

+ (instancetype)accessoryView {
    AMEKeyboardAccessoryView *view = [[self alloc] initWithFrame:CGRectMake(0, 0, 320, 48)
                                                  inputViewStyle:UIInputViewStyleKeyboard];
    return view;
}

- (instancetype)initWithFrame:(CGRect)frame inputViewStyle:(UIInputViewStyle)inputViewStyle {
    self = [super initWithFrame:frame inputViewStyle:inputViewStyle];
    if (!self) return nil;
    self.allowsSelfSizing = YES;
    self.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *keys = [[UIStackView alloc] init];
    keys.axis = UILayoutConstraintAxisHorizontal;
    keys.spacing = 6;
    keys.distribution = UIStackViewDistributionFillEqually;
    keys.translatesAutoresizingMaskIntoConstraints = NO;

    [keys addArrangedSubview:[self buttonWithTitle:@"esc" symbol:nil kind:AMEAccessoryKindKey value:GLFW_KEY_ESCAPE label:@"Escape"]];
    [keys addArrangedSubview:[self buttonWithTitle:@"tab" symbol:nil kind:AMEAccessoryKindKey value:GLFW_KEY_TAB label:@"Tab"]];
    [keys addArrangedSubview:[self buttonWithTitle:@"/" symbol:nil kind:AMEAccessoryKindCharacter value:'/' label:@"Slash"]];
    [keys addArrangedSubview:[self buttonWithTitle:nil symbol:@"arrow.left" kind:AMEAccessoryKindKey value:GLFW_KEY_DPAD_LEFT label:@"Left arrow"]];
    [keys addArrangedSubview:[self buttonWithTitle:nil symbol:@"arrow.up" kind:AMEAccessoryKindKey value:GLFW_KEY_DPAD_UP label:@"Up arrow"]];
    [keys addArrangedSubview:[self buttonWithTitle:nil symbol:@"arrow.down" kind:AMEAccessoryKindKey value:GLFW_KEY_DPAD_DOWN label:@"Down arrow"]];
    [keys addArrangedSubview:[self buttonWithTitle:nil symbol:@"arrow.right" kind:AMEAccessoryKindKey value:GLFW_KEY_DPAD_RIGHT label:@"Right arrow"]];

    UIButton *hide = [self buttonWithTitle:nil symbol:@"keyboard.chevron.compact.down" kind:AMEAccessoryKindDismiss value:0 label:@"Hide keyboard"];
    hide.translatesAutoresizingMaskIntoConstraints = NO;

    [self addSubview:keys];
    [self addSubview:hide];

    UILayoutGuide *safe = self.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.heightAnchor constraintEqualToConstant:48],
        [keys.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8],
        [keys.topAnchor constraintEqualToAnchor:self.topAnchor constant:6],
        [keys.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-6],
        [keys.trailingAnchor constraintEqualToAnchor:hide.leadingAnchor constant:-12],
        [hide.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8],
        [hide.topAnchor constraintEqualToAnchor:keys.topAnchor],
        [hide.bottomAnchor constraintEqualToAnchor:keys.bottomAnchor],
        [hide.widthAnchor constraintEqualToConstant:56],
    ]];
    return self;
}

- (UIButton *)buttonWithTitle:(NSString *)title
                       symbol:(NSString *)symbol
                         kind:(AMEAccessoryKind)kind
                        value:(NSInteger)value
                        label:(NSString *)label {
    UIImage *image = symbol
        ? [UIImage systemImageNamed:symbol
                  withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold]]
        : nil;
    UIFont *font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightSemibold];

    UIButton *button;
    if (@available(iOS 15.0, *)) {
        UIButtonConfiguration *config = (kind == AMEAccessoryKindDismiss)
            ? [UIButtonConfiguration filledButtonConfiguration]
            : [UIButtonConfiguration grayButtonConfiguration];
        config.cornerStyle = UIButtonConfigurationCornerStyleMedium;
        config.contentInsets = NSDirectionalEdgeInsetsMake(4, 4, 4, 4);
        config.image = image;
        if (title) {
            config.attributedTitle = [[NSAttributedString alloc] initWithString:title
                                                                     attributes:@{NSFontAttributeName: font}];
        }
        button = [UIButton buttonWithConfiguration:config primaryAction:nil];
    } else {
        button = [UIButton buttonWithType:UIButtonTypeSystem];
        [button setImage:image forState:UIControlStateNormal];
        [button setTitle:title forState:UIControlStateNormal];
        button.titleLabel.font = font;
        button.backgroundColor = (kind == AMEAccessoryKindDismiss) ? UIColor.systemBlueColor : UIColor.tertiarySystemFillColor;
        button.tintColor = (kind == AMEAccessoryKindDismiss) ? UIColor.whiteColor : UIColor.labelColor;
        button.layer.cornerRadius = 8;
    }
    button.accessibilityLabel = label;
    button.tag = value;

    __weak typeof(self) weakSelf = self;
    [button addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [[UIDevice currentDevice] playInputClick];
        switch (kind) {
            case AMEAccessoryKindKey:
                if (self.onKey) self.onKey((int)value);
                break;
            case AMEAccessoryKindCharacter:
                if (self.onCharacter) self.onCharacter((unichar)value);
                break;
            case AMEAccessoryKindDismiss:
                if (self.onDismiss) self.onDismiss();
                break;
        }
    }] forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (BOOL)enableInputClicksWhenVisible {
    return YES;
}

@end
