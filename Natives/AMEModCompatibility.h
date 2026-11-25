//
//  AMEModCompatibility.h
//  Checks a Fabric/Quilt mods folder for the conflicts Fabric would refuse to
//  launch with (a mod needing an exact version of another, or declaring it
//  "breaks" a version that's installed), so the launcher can explain the
//  problem and offer a fix instead of the game exiting.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AMEModConflict : NSObject
@property(nonatomic, copy) NSString *message;        // plain-English explanation
@property(nonatomic, copy) NSString *disableName;    // mod the fix disables
@property(nonatomic, copy) NSString *disablePath;    // its .jar
@end

@interface AMEModCompatibility : NSObject

/// Conflicts among the enabled .jar files in a mods folder (empty if none).
+ (NSArray<AMEModConflict *> *)conflictsInModsFolder:(NSString *)modsFolder;

/// Checks the instance's mods before launching. If there's a conflict, asks the
/// user (disable the offending mod and play / cancel); calls `play` when it's OK.
+ (void)checkProfile:(NSString *)profileName presenter:(UIViewController *)presenter play:(void (^)(void))play;

@end

NS_ASSUME_NONNULL_END
