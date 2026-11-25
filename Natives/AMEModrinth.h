//
//  AMEModrinth.h
//  Minimal Modrinth client for the redesigned launcher: search projects that
//  fit an instance (Minecraft version + loader) and install them, including
//  required dependencies, into that instance's folder.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, AMEModrinthKind) {
    AMEModrinthKindMod,
    AMEModrinthKindShader,
    AMEModrinthKindResourcePack,
};

/// What an instance is: where its files go and what it can run.
@interface AMEInstanceInfo : NSObject
@property(nonatomic, copy) NSString *profileName;
@property(nonatomic, copy) NSString *versionId;           // e.g. fabric-loader-0.20.1-1.21.1
@property(nonatomic, copy, nullable) NSString *gameVersion; // e.g. 1.21.1 (nil if unknown)
@property(nonatomic, copy, nullable) NSString *loader;      // "fabric", "quilt", "forge", "neoforge" or nil (vanilla)
@property(nonatomic, copy) NSString *gameDirectory;       // absolute
+ (nullable instancetype)infoForProfileName:(NSString *)profileName;
- (NSString *)folderForKind:(AMEModrinthKind)kind;        // mods / shaderpacks / resourcepacks
@end

@interface AMEModrinthProject : NSObject
@property(nonatomic, copy) NSString *projectId;
@property(nonatomic, copy) NSString *slug;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *summary;
@property(nonatomic, copy) NSString *author;
@property(nonatomic, copy, nullable) NSURL *iconURL;
@property(nonatomic) NSInteger downloads;
@end

@interface AMEModrinth : NSObject

/// Searches Modrinth. Empty query = most downloaded. Completion on main queue.
+ (void)searchQuery:(NSString *)query
               kind:(AMEModrinthKind)kind
           instance:(AMEInstanceInfo *)instance
             offset:(NSInteger)offset
         completion:(void (^)(NSArray<AMEModrinthProject *> *_Nullable results, NSInteger totalHits, NSError *_Nullable error))completion;

/// Installs the newest compatible version of a project (and, for mods, its
/// required dependencies). Completion on main queue with the installed file names.
+ (void)installProject:(NSString *)projectIdOrSlug
                  kind:(AMEModrinthKind)kind
              instance:(AMEInstanceInfo *)instance
            completion:(void (^)(NSArray<NSString *> *_Nullable installedFiles, NSError *_Nullable error))completion;

/// Whether this launcher already installed the project into the instance.
+ (BOOL)isProjectInstalled:(NSString *)projectId kind:(AMEModrinthKind)kind instance:(AMEInstanceInfo *)instance;

/// Downloads a small image (cached in memory).
+ (void)loadIcon:(NSURL *)url completion:(void (^)(NSData *_Nullable data))completion;

@end

NS_ASSUME_NONNULL_END
