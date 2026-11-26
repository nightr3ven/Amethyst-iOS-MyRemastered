//
//  AMEModsViewController.h
//  Redesigned "Mods" page for an instance: readable names/versions/icons,
//  one-tap on/off, conflict warnings, Get mods (Modrinth) and import.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AMEModsViewController : UITableViewController
- (instancetype)initWithProfileName:(NSString *)profileName;
@end

NS_ASSUME_NONNULL_END
