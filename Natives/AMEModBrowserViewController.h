//
//  AMEModBrowserViewController.h
//  Browse Modrinth for one instance and install with one tap.
//  Results are already filtered to the instance's Minecraft version and loader.
//

#import <UIKit/UIKit.h>
#import "AMEModrinth.h"

NS_ASSUME_NONNULL_BEGIN

@interface AMEModBrowserViewController : UITableViewController
- (instancetype)initWithProfileName:(NSString *)profileName kind:(AMEModrinthKind)kind;
@end

NS_ASSUME_NONNULL_END
