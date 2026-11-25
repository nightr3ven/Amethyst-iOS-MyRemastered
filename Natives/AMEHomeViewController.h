//
//  AMEHomeViewController.h
//  Redesigned Home tab: one card with the selected version, account and a big
//  Play button, followed by plain grouped lists of the things you can do.
//
//  Launching, version picking and account switching are still performed by the
//  (hidden) LauncherRightPanelViewController; this screen only sends it actions
//  and shows the state it broadcasts.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AMEHomeViewController : UITableViewController
@end

NS_ASSUME_NONNULL_END
