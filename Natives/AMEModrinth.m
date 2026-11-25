//
//  AMEModrinth.m
//

#import "AMEModrinth.h"
#import "PLProfiles.h"
#import "utils.h"

static NSString *const kAPI = @"https://api.modrinth.com/v2";
static NSString *const kIndexFile = @".ame-modrinth.json";   // projectId -> file name, per folder

#pragma mark - Instance info

@implementation AMEInstanceInfo

+ (instancetype)infoForProfileName:(NSString *)profileName {
    NSDictionary *profile = PLProfiles.current.profiles[profileName];
    if (![profile isKindOfClass:NSDictionary.class]) return nil;

    AMEInstanceInfo *info = [[AMEInstanceInfo alloc] init];
    info.profileName = profileName;
    NSString *versionId = profile[@"lastVersionId"];
    info.versionId = [versionId isKindOfClass:NSString.class] ? versionId : @"";
    info.gameDirectory = amePCLVersionGameDirAbsolute(profile, nil);

    NSString *lower = info.versionId.lowercaseString;
    if ([lower containsString:@"neoforge"]) info.loader = @"neoforge";
    else if ([lower containsString:@"forge"]) info.loader = @"forge";
    else if ([lower containsString:@"fabric"]) info.loader = @"fabric";
    else if ([lower containsString:@"quilt"]) info.loader = @"quilt";

    // The installed version json knows the real Minecraft version (inheritsFrom).
    const char *gameDir = getenv("POJAV_GAME_DIR");
    if (gameDir && info.versionId.length) {
        NSString *json = [NSString stringWithFormat:@"%s/versions/%@/%@.json", gameDir, info.versionId, info.versionId];
        NSData *data = [NSData dataWithContentsOfFile:json];
        NSDictionary *dict = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSString *inherits = [dict isKindOfClass:NSDictionary.class] ? dict[@"inheritsFrom"] : nil;
        if ([inherits isKindOfClass:NSString.class] && inherits.length) info.gameVersion = inherits;
    }
    if (!info.gameVersion) {
        if (info.loader == nil && ![info.versionId hasPrefix:@"latest-"] && info.versionId.length) {
            info.gameVersion = info.versionId;   // vanilla id is the Minecraft version
        } else if ([info.versionId hasPrefix:@"fabric-loader-"] || [info.versionId hasPrefix:@"quilt-loader-"]) {
            NSArray *parts = [info.versionId componentsSeparatedByString:@"-"];
            if (parts.count >= 4) info.gameVersion = [[parts subarrayWithRange:NSMakeRange(3, parts.count - 3)] componentsJoinedByString:@"-"];
        }
    }
    return info;
}

- (NSString *)folderForKind:(AMEModrinthKind)kind {
    NSString *name = kind == AMEModrinthKindMod ? @"mods"
                   : kind == AMEModrinthKindShader ? @"shaderpacks" : @"resourcepacks";
    return [self.gameDirectory stringByAppendingPathComponent:name];
}

@end

@implementation AMEModrinthProject
@end

#pragma mark - Client

@implementation AMEModrinth

+ (NSURLSession *)session {
    static NSURLSession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *c = NSURLSessionConfiguration.defaultSessionConfiguration;
        c.HTTPAdditionalHeaders = @{@"User-Agent": @"Air-iOS-launcher/redesign"};
        c.timeoutIntervalForRequest = 30;
        session = [NSURLSession sessionWithConfiguration:c];
    });
    return session;
}

+ (void)getJSON:(NSURL *)url completion:(void (^)(id _Nullable json, NSError *_Nullable error))completion {
    [[self.session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error && [(NSHTTPURLResponse *)response statusCode] >= 400) {
            error = [NSError errorWithDomain:@"Modrinth" code:[(NSHTTPURLResponse *)response statusCode]
                                    userInfo:@{NSLocalizedDescriptionKey: @"Modrinth returned an error. Try again in a moment."}];
        }
        id json = (!error && data) ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
        completion(json, error);
    }] resume];
}

+ (NSString *)jsonString:(id)obj {
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
}

+ (NSURL *)urlWithPath:(NSString *)path query:(NSDictionary<NSString *, NSString *> *)query {
    NSURLComponents *c = [NSURLComponents componentsWithString:[kAPI stringByAppendingString:path]];
    NSMutableArray *items = [NSMutableArray array];
    [query enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
        [items addObject:[NSURLQueryItem queryItemWithName:k value:v]];
    }];
    c.queryItems = items;
    return c.URL;
}

/// Loader filter Modrinth understands for each kind.
+ (NSArray<NSString *> *)loadersForKind:(AMEModrinthKind)kind instance:(AMEInstanceInfo *)instance {
    switch (kind) {
        case AMEModrinthKindMod:
            if ([instance.loader isEqualToString:@"quilt"]) return @[@"quilt", @"fabric"];  // Quilt runs Fabric mods
            return instance.loader ? @[instance.loader] : @[];
        case AMEModrinthKindShader:       return @[@"iris", @"optifine", @"canvas", @"vanilla"];
        case AMEModrinthKindResourcePack: return @[@"minecraft"];
    }
    return @[];
}

+ (NSString *)projectTypeForKind:(AMEModrinthKind)kind {
    return kind == AMEModrinthKindMod ? @"mod" : kind == AMEModrinthKindShader ? @"shader" : @"resourcepack";
}

#pragma mark Search

+ (void)searchQuery:(NSString *)query kind:(AMEModrinthKind)kind instance:(AMEInstanceInfo *)instance offset:(NSInteger)offset
         completion:(void (^)(NSArray<AMEModrinthProject *> *, NSInteger, NSError *))completion {
    NSMutableArray *facets = [NSMutableArray arrayWithObject:@[[@"project_type:" stringByAppendingString:[self projectTypeForKind:kind]]]];
    if (instance.gameVersion) [facets addObject:@[[@"versions:" stringByAppendingString:instance.gameVersion]]];
    NSArray *loaders = [self loadersForKind:kind instance:instance];
    if (kind == AMEModrinthKindMod && loaders.count) {
        NSMutableArray *any = [NSMutableArray array];
        for (NSString *l in loaders) [any addObject:[@"categories:" stringByAppendingString:l]];
        [facets addObject:any];
    }

    NSURL *url = [self urlWithPath:@"/search" query:@{
        @"query": query ?: @"",
        @"facets": [self jsonString:facets],
        @"index": query.length ? @"relevance" : @"downloads",
        @"limit": @"30",
        @"offset": [NSString stringWithFormat:@"%ld", (long)offset],
    }];
    [self getJSON:url completion:^(NSDictionary *json, NSError *error) {
        NSMutableArray *results = [NSMutableArray array];
        for (NSDictionary *hit in json[@"hits"]) {
            AMEModrinthProject *p = [[AMEModrinthProject alloc] init];
            p.projectId = hit[@"project_id"] ?: @"";
            p.slug = hit[@"slug"] ?: p.projectId;
            p.title = hit[@"title"] ?: p.slug;
            p.summary = hit[@"description"] ?: @"";
            p.author = hit[@"author"] ?: @"";
            NSString *icon = hit[@"icon_url"];
            p.iconURL = [icon isKindOfClass:NSString.class] && icon.length ? [NSURL URLWithString:icon] : nil;
            p.downloads = [hit[@"downloads"] integerValue];
            [results addObject:p];
        }
        NSInteger total = [json[@"total_hits"] integerValue];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(error ? nil : results, total, error);
        });
    }];
}

#pragma mark Install

+ (NSMutableDictionary *)indexForFolder:(NSString *)folder {
    NSData *d = [NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:kIndexFile]];
    NSDictionary *idx = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    return [idx isKindOfClass:NSDictionary.class] ? idx.mutableCopy : [NSMutableDictionary dictionary];
}

+ (void)saveIndex:(NSDictionary *)index forFolder:(NSString *)folder {
    NSData *d = [NSJSONSerialization dataWithJSONObject:index options:NSJSONWritingPrettyPrinted error:nil];
    [d writeToFile:[folder stringByAppendingPathComponent:kIndexFile] atomically:YES];
}

+ (BOOL)isProjectInstalled:(NSString *)projectId kind:(AMEModrinthKind)kind instance:(AMEInstanceInfo *)instance {
    NSString *folder = [instance folderForKind:kind];
    id file = [self indexForFolder:folder][projectId];
    if (![file isKindOfClass:NSString.class]) return NO;
    return [(NSString *)file length] && [NSFileManager.defaultManager fileExistsAtPath:[folder stringByAppendingPathComponent:file]];
}

+ (void)installProject:(NSString *)project kind:(AMEModrinthKind)kind instance:(AMEInstanceInfo *)instance
            completion:(void (^)(NSArray<NSString *> *, NSError *))completion {
    NSMutableArray<NSString *> *installed = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    [self installOne:project pinnedVersion:nil kind:kind instance:instance depth:0 seen:seen installed:installed completion:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(error ? nil : installed, error);
        });
    }];
}

// Some mods require an exact version of another (Iris pins the Sodium it was built
// against; a newer Sodium declares it "breaks" that Iris). Those pins are honoured
// and remembered per folder, so installing that dependency directly later keeps
// the pinned version instead of upgrading into a crash.
+ (NSMutableDictionary *)pinsInIndex:(NSMutableDictionary *)index {
    NSMutableDictionary *pins = [index[@"__pins"] isKindOfClass:NSDictionary.class] ? [index[@"__pins"] mutableCopy] : [NSMutableDictionary dictionary];
    return pins;
}

+ (void)installOne:(NSString *)project pinnedVersion:(nullable NSString *)pinnedVersion kind:(AMEModrinthKind)kind instance:(AMEInstanceInfo *)instance depth:(NSInteger)depth
              seen:(NSMutableSet *)seen installed:(NSMutableArray *)installed completion:(void (^)(NSError *_Nullable))completion {
    if ([seen containsObject:project] || depth > 6) { completion(nil); return; }
    [seen addObject:project];

    if (pinnedVersion.length) {
        NSURL *url = [self urlWithPath:[NSString stringWithFormat:@"/version/%@", pinnedVersion] query:@{}];
        [self getJSON:url completion:^(NSDictionary *version, NSError *error) {
            if (error || ![version isKindOfClass:NSDictionary.class]) { completion(error); return; }
            [self installVersion:version pinned:YES kind:kind instance:instance depth:depth seen:seen installed:installed completion:completion];
        }];
        return;
    }

    NSMutableDictionary *query = [NSMutableDictionary dictionary];
    NSArray *loaders = [self loadersForKind:kind instance:instance];
    if (loaders.count) query[@"loaders"] = [self jsonString:loaders];
    if (instance.gameVersion) query[@"game_versions"] = [self jsonString:@[instance.gameVersion]];
    NSURL *url = [self urlWithPath:[NSString stringWithFormat:@"/project/%@/version", project] query:query];

    [self getJSON:url completion:^(NSArray *versions, NSError *error) {
        if (error) { completion(error); return; }
        if (![versions isKindOfClass:NSArray.class] || versions.count == 0) {
            NSString *what = instance.gameVersion
                ? [NSString stringWithFormat:@"Minecraft %@%@", instance.gameVersion, instance.loader ? [@" with " stringByAppendingString:instance.loader.capitalizedString] : @""]
                : @"this instance";
            completion([NSError errorWithDomain:@"Modrinth" code:404 userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"There's no version of this for %@.", what]}]);
            return;
        }
        NSString *projectId = versions.firstObject[@"project_id"] ?: project;
        // Another installed mod needs a specific version of this one: use that.
        NSString *pin = [self pinsInIndex:[self indexForFolder:[instance folderForKind:kind]]][projectId];
        if ([pin isKindOfClass:NSString.class] && pin.length) {
            for (NSDictionary *v in versions) {
                if ([v[@"id"] isEqualToString:pin]) {
                    [self installVersion:v pinned:YES kind:kind instance:instance depth:depth seen:seen installed:installed completion:completion];
                    return;
                }
            }
        }
        // Prefer the newest release, else the newest of anything.
        NSDictionary *version = versions.firstObject;
        for (NSDictionary *v in versions) {
            if ([v[@"version_type"] isEqualToString:@"release"]) { version = v; break; }
        }
        [self installVersion:version pinned:NO kind:kind instance:instance depth:depth seen:seen installed:installed completion:completion];
    }];
}

+ (void)installVersion:(NSDictionary *)version pinned:(BOOL)pinned kind:(AMEModrinthKind)kind instance:(AMEInstanceInfo *)instance depth:(NSInteger)depth
                  seen:(NSMutableSet *)seen installed:(NSMutableArray *)installed completion:(void (^)(NSError *_Nullable))completion {
    {
        NSArray *files = version[@"files"];
        NSDictionary *file = files.firstObject;
        for (NSDictionary *f in files) if ([f[@"primary"] boolValue]) { file = f; break; }
        NSString *projectId = version[@"project_id"] ?: @"";
        NSString *versionId = version[@"id"] ?: @"";
        NSMutableDictionary *currentIndex = [self indexForFolder:[instance folderForKind:kind]];
        NSDictionary *versionsIdx = [currentIndex[@"__versions"] isKindOfClass:NSDictionary.class] ? currentIndex[@"__versions"] : @{};
        if ([self isProjectInstalled:projectId kind:kind instance:instance] && [versionsIdx[projectId] isEqual:versionId]) {
            completion(nil);   // exactly this version is already there
            return;
        }
        if ([self isProjectInstalled:projectId kind:kind instance:instance] && depth > 0 && !pinned) { completion(nil); return; }

        NSString *folder = [instance folderForKind:kind];
        [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *fileURL = [NSURL URLWithString:file[@"url"] ?: @""];
        NSString *fileName = [file[@"filename"] lastPathComponent];
        if (!fileURL || fileName.length == 0) {
            completion([NSError errorWithDomain:@"Modrinth" code:500 userInfo:@{NSLocalizedDescriptionKey: @"This version has no file to download."}]);
            return;
        }

        [[self.session downloadTaskWithURL:fileURL completionHandler:^(NSURL *location, NSURLResponse *response, NSError *dlError) {
            if (dlError || !location) { completion(dlError); return; }
            NSString *dest = [folder stringByAppendingPathComponent:fileName];
            NSFileManager *fm = NSFileManager.defaultManager;
            // Replace an older file of the same project, if we installed one.
            NSMutableDictionary *index = [self indexForFolder:folder];
            NSString *old = index[projectId];
            if (old.length && ![old isEqualToString:fileName]) [fm removeItemAtPath:[folder stringByAppendingPathComponent:old] error:nil];
            [fm removeItemAtPath:dest error:nil];
            NSError *moveError = nil;
            [fm moveItemAtURL:location toURL:[NSURL fileURLWithPath:dest] error:&moveError];
            if (moveError) { completion(moveError); return; }
            index[projectId] = fileName;
            NSMutableDictionary *versionsIndex = [index[@"__versions"] isKindOfClass:NSDictionary.class] ? [index[@"__versions"] mutableCopy] : [NSMutableDictionary dictionary];
            versionsIndex[projectId] = versionId;
            index[@"__versions"] = versionsIndex;
            [self saveIndex:index forFolder:folder];
            @synchronized (installed) { [installed addObject:fileName]; }

            // Required dependencies (mods only), one after another.
            NSMutableArray<NSDictionary *> *deps = [NSMutableArray array];
            if (kind == AMEModrinthKindMod) {
                NSMutableDictionary *pins = [self pinsInIndex:index];
                for (NSDictionary *d in version[@"dependencies"]) {
                    if (![d[@"dependency_type"] isEqualToString:@"required"]) continue;
                    NSString *pid = d[@"project_id"];
                    NSString *vid = [d[@"version_id"] isKindOfClass:NSString.class] ? d[@"version_id"] : nil;
                    if (![pid isKindOfClass:NSString.class] && vid == nil) continue;
                    if (vid && [pid isKindOfClass:NSString.class]) pins[pid] = vid;
                    [deps addObject:@{@"project": [pid isKindOfClass:NSString.class] ? pid : vid, @"version": vid ?: @""}];
                }
                if (pins.count) {
                    index[@"__pins"] = pins;
                    [self saveIndex:index forFolder:folder];
                }
            }
            [self installDependencies:deps kind:kind instance:instance depth:depth seen:seen installed:installed completion:completion];
        }] resume];
    }
}

+ (void)installDependencies:(NSMutableArray<NSDictionary *> *)deps kind:(AMEModrinthKind)kind instance:(AMEInstanceInfo *)instance depth:(NSInteger)depth
                       seen:(NSMutableSet *)seen installed:(NSMutableArray *)installed completion:(void (^)(NSError *_Nullable))completion {
    if (deps.count == 0) { completion(nil); return; }
    NSDictionary *next = deps.firstObject;
    [deps removeObjectAtIndex:0];
    NSString *project = next[@"project"];
    NSString *version = [next[@"version"] length] ? next[@"version"] : nil;
    if (!version && [self isProjectInstalled:project kind:kind instance:instance]) {
        [self installDependencies:deps kind:kind instance:instance depth:depth seen:seen installed:installed completion:completion];
        return;
    }
    [self installOne:project pinnedVersion:version kind:kind instance:instance depth:depth + 1 seen:seen installed:installed completion:^(NSError *error) {
        // A dependency failing shouldn't undo the main install; keep going.
        [self installDependencies:deps kind:kind instance:instance depth:depth seen:seen installed:installed completion:completion];
    }];
}

#pragma mark Icons

+ (void)loadIcon:(NSURL *)url completion:(void (^)(NSData *))completion {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [[NSCache alloc] init]; cache.countLimit = 300; });
    NSData *hit = [cache objectForKey:url];
    if (hit) { completion(hit); return; }
    [[self.session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        if (data) [cache setObject:data forKey:url];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(data); });
    }] resume];
}

@end
