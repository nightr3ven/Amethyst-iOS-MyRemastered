//
//  AMEPacksViewController.h
//  Redesigned Shaders / Resource packs pages for an instance.
//  Shaders: pick one (or Off), written to config/iris.properties.
//  Resource packs: on/off switches, written to options.txt.
//

#import <UIKit/UIKit.h>
#import "AMEModrinth.h"

NS_ASSUME_NONNULL_BEGIN

@interface AMEPacksViewController : UITableViewController
/// kind must be AMEModrinthKindShader or AMEModrinthKindResourcePack.
- (instancetype)initWithProfileName:(NSString *)profileName kind:(AMEModrinthKind)kind;
@end

NS_ASSUME_NONNULL_END
