//
//  AMEInstancesViewController.h
//  Redesigned Instances tab.
//
//  An "instance" is a launcher profile: a name plus a Minecraft version (vanilla
//  or with a mod loader) and its settings. With isolation on, each instance's
//  version keeps its own mods, config, saves, resource packs and shaders.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// List of every instance. Tap one to open it.
@interface AMEInstancesViewController : UITableViewController
@end

/// One instance: Play, its content (mods, shaders, worlds, ...), its settings.
@interface AMEInstanceViewController : UITableViewController
- (instancetype)initWithProfileName:(NSString *)profileName;
@end

/// Helpers shared by the redesigned screens.
NSString *AMEInstanceLoaderName(NSString *_Nullable versionId);
UIColor *AMEInstanceLoaderColor(NSString *_Nullable versionId);
void AMESelectInstance(NSString *profileName);

NS_ASSUME_NONNULL_END
