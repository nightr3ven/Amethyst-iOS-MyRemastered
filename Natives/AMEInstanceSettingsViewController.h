//
//  AMEInstanceSettingsViewController.h
//  Redesigned per-instance settings: name, renderer, graphics API (26.x),
//  Java version, JVM arguments and auto-join server. Writes the same profile
//  keys the launcher reads at launch (renderer, graphicsApi, javaVersion,
//  javaArgs, serverIp).
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AMEInstanceSettingsViewController : UITableViewController
- (instancetype)initWithProfileName:(NSString *)profileName;
@end

/// Simple single-choice list (Settings-app style).
@interface AMEOptionPickerViewController : UITableViewController
- (instancetype)initWithTitle:(NSString *)title
                       values:(NSArray<NSString *> *)values
                       titles:(NSArray<NSString *> *)titles
                    subtitles:(nullable NSArray<NSString *> *)subtitles
                     selected:(nullable NSString *)selected
                       footer:(nullable NSString *)footer
                       onPick:(void (^)(NSString *value))onPick;
@end

NS_ASSUME_NONNULL_END
