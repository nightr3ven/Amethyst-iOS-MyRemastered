//
//  AMENewInstanceViewController.h
//  Create an instance: name, Minecraft version, and Vanilla / Fabric / Quilt.
//  Each new instance gets its own folder (mods, config, worlds, packs).
//  Game files download the first time you press Play.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AMENewInstanceViewController : UITableViewController
/// Called with the new profile name after it was created.
@property(nonatomic, copy, nullable) void (^onCreated)(NSString *profileName);
@end

NS_ASSUME_NONNULL_END
