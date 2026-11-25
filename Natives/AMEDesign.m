//
//  AMEDesign.m
//

#import "AMEDesign.h"
#import "utils.h"

NSString *AMEL(NSString *key, NSString *english) {
    NSString *value = localize(key, nil);
    if (value.length == 0 || [value isEqualToString:key]) return english;
    return value;
}

@implementation AMEDesign

+ (UIColor *)accentColor {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithRed:0.33 green:0.78 blue:0.42 alpha:1.0]
            : [UIColor colorWithRed:0.20 green:0.62 blue:0.30 alpha:1.0];
    }];
}

+ (CGFloat)cardCornerRadius {
    return 20.0;
}

+ (UIButton *)buttonWithTitle:(NSString *)title symbol:(NSString *)symbol style:(AMEButtonStyle)style {
    BOOL primary = (style == AMEButtonStylePrimary);
    UIImage *image = symbol
        ? [UIImage systemImageNamed:symbol withConfiguration:
            [UIImageSymbolConfiguration configurationWithTextStyle:primary ? UIFontTextStyleTitle3 : UIFontTextStyleSubheadline
                                                             scale:UIImageSymbolScaleMedium]]
        : nil;

    UIButton *button;
    if (@available(iOS 15.0, *)) {
        UIButtonConfiguration *config = primary
            ? [UIButtonConfiguration filledButtonConfiguration]
            : [UIButtonConfiguration grayButtonConfiguration];
        config.cornerStyle = primary ? UIButtonConfigurationCornerStyleCapsule
                                     : UIButtonConfigurationCornerStyleMedium;
        config.image = image;
        config.imagePadding = 8;
        config.buttonSize = primary ? UIButtonConfigurationSizeLarge : UIButtonConfigurationSizeMedium;
        config.titleLineBreakMode = NSLineBreakByTruncatingTail;
        if (primary) {
            config.baseBackgroundColor = AMEDesign.accentColor;
            config.baseForegroundColor = UIColor.whiteColor;
        } else {
            config.baseForegroundColor = UIColor.labelColor;
        }
        button = [UIButton buttonWithConfiguration:config primaryAction:nil];
        [self setTitle:title ofButton:button];
    } else {
        button = [UIButton buttonWithType:UIButtonTypeSystem];
        [button setImage:image forState:UIControlStateNormal];
        [button setTitle:title forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont preferredFontForTextStyle:primary ? UIFontTextStyleTitle3 : UIFontTextStyleSubheadline];
        button.backgroundColor = primary ? AMEDesign.accentColor : UIColor.tertiarySystemFillColor;
        button.tintColor = primary ? UIColor.whiteColor : UIColor.labelColor;
        button.layer.cornerRadius = primary ? 28 : 10;
        button.contentEdgeInsets = UIEdgeInsetsMake(10, 14, 10, 14);
    }
    button.titleLabel.adjustsFontForContentSizeCategory = YES;
    return button;
}

+ (void)setTitle:(NSString *)title ofButton:(UIButton *)button {
    if (@available(iOS 15.0, *)) {
        if (button.configuration) {
            UIButtonConfiguration *config = button.configuration;
            BOOL primary = (config.buttonSize == UIButtonConfigurationSizeLarge);
            UIFont *font = [UIFont preferredFontForTextStyle:primary ? UIFontTextStyleTitle3 : UIFontTextStyleSubheadline];
            if (primary) {
                font = [UIFont fontWithDescriptor:[font.fontDescriptor fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitBold] size:0];
            }
            config.attributedTitle = title
                ? [[NSAttributedString alloc] initWithString:title attributes:@{NSFontAttributeName: font}]
                : nil;
            button.configuration = config;
            return;
        }
    }
    [button setTitle:title forState:UIControlStateNormal];
}

+ (UIImage *)iconTileWithSymbol:(NSString *)symbol color:(UIColor *)color {
    CGFloat side = 29;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:format];
    UIImage *glyph = [[UIImage systemImageNamed:symbol withConfiguration:
                        [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold]]
                      imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
    UIImage *tile = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, side, side) cornerRadius:7];
        [color setFill];
        [path fill];
        if (glyph) {
            CGSize g = glyph.size;
            [glyph drawInRect:CGRectMake((side - g.width) / 2, (side - g.height) / 2, g.width, g.height)];
        }
    }];
    return [tile imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

+ (void)styleCard:(UIView *)view {
    view.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    view.layer.cornerRadius = self.cardCornerRadius;
    if (@available(iOS 13.0, *)) {
        view.layer.cornerCurve = kCACornerCurveContinuous;
    }
}

@end
