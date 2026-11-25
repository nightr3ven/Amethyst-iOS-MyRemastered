//
//  AMEModCompatibility.m
//

#import "AMEModCompatibility.h"
#import "AMEModrinth.h"
#import "UZKArchive.h"

@implementation AMEModConflict
@end

@interface AMEModInfo : NSObject
@property(nonatomic, copy) NSString *modId, *name, *version, *path;
@property(nonatomic, copy) NSArray<NSString *> *provides;
@property(nonatomic, copy) NSDictionary *depends, *breaks;
@end
@implementation AMEModInfo
@end

#pragma mark - Versions

/// Numeric core, pre-release flag. Build metadata (+...) is ignored, as Fabric does.
static NSArray *AMEParseVersion(NSString *v) {
    NSString *core = [v componentsSeparatedByString:@"+"].firstObject ?: @"";
    NSRange dash = [core rangeOfString:@"-"];
    BOOL pre = dash.location != NSNotFound;
    if (pre) core = [core substringToIndex:dash.location];
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *p in [core componentsSeparatedByString:@"."]) {
        NSScanner *s = [NSScanner scannerWithString:p];
        NSInteger n = 0;
        if (![s scanInteger:&n]) return nil;   // not semantic: don't judge
        [parts addObject:@(n)];
    }
    return @[parts, @(pre)];
}

static NSComparisonResult AMECompareVersions(NSString *a, NSString *b, BOOL *ok) {
    NSArray *pa = AMEParseVersion(a), *pb = AMEParseVersion(b);
    if (!pa || !pb) { *ok = NO; return NSOrderedSame; }
    *ok = YES;
    NSArray *na = pa[0], *nb = pb[0];
    for (NSUInteger i = 0; i < MAX(na.count, nb.count); i++) {
        NSInteger x = i < na.count ? [na[i] integerValue] : 0;
        NSInteger y = i < nb.count ? [nb[i] integerValue] : 0;
        if (x != y) return x < y ? NSOrderedAscending : NSOrderedDescending;
    }
    BOOL preA = [pa[1] boolValue], preB = [pb[1] boolValue];
    if (preA != preB) return preA ? NSOrderedAscending : NSOrderedDescending;
    return NSOrderedSame;
}

/// One Fabric version predicate term (">=1.2", "0.9.x", "*", "=1.0", "~1.2", "^1.2", "1.0").
/// Returns YES when satisfied or when the term can't be understood (no false alarms).
static BOOL AMETermMatches(NSString *term, NSString *version) {
    term = [term stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (term.length == 0 || [term isEqualToString:@"*"]) return YES;
    NSString *op = @"=";
    for (NSString *candidate in @[@">=", @"<=", @">", @"<", @"=", @"~", @"^"]) {
        if ([term hasPrefix:candidate]) { op = candidate; term = [term substringFromIndex:candidate.length]; break; }
    }
    if ([term containsString:@"x"] || [term containsString:@"X"] || [term containsString:@"*"]) {
        NSString *prefix = [[[term stringByReplacingOccurrencesOfString:@"X" withString:@"x"]
                             stringByReplacingOccurrencesOfString:@"*" withString:@"x"] componentsSeparatedByString:@"x"].firstObject;
        return [version hasPrefix:prefix];
    }
    BOOL ok = NO;
    NSComparisonResult c = AMECompareVersions(version, term, &ok);
    if (!ok) return YES;
    if ([op isEqualToString:@"="])  return c == NSOrderedSame;
    if ([op isEqualToString:@">="]) return c != NSOrderedAscending;
    if ([op isEqualToString:@"<="]) return c != NSOrderedDescending;
    if ([op isEqualToString:@">"])  return c == NSOrderedDescending;
    if ([op isEqualToString:@"<"])  return c == NSOrderedAscending;
    NSArray *parts = AMEParseVersion(term)[0];
    if (c == NSOrderedAscending || parts.count == 0) return NO;
    // ~1.2 => <1.3, ^1.2 => <2.0
    NSMutableArray *upper = [parts mutableCopy];
    NSUInteger bump = [op isEqualToString:@"~"] ? MIN(1, upper.count - 1) : 0;
    upper[bump] = @([upper[bump] integerValue] + 1);
    for (NSUInteger i = bump + 1; i < upper.count; i++) upper[i] = @0;
    return AMECompareVersions(version, [upper componentsJoinedByString:@"."], &ok) == NSOrderedAscending || !ok;
}

/// Predicate: string (space-separated terms, all must match) or array (any matches).
static BOOL AMEPredicateMatches(id predicate, NSString *version) {
    if ([predicate isKindOfClass:NSArray.class]) {
        for (id p in predicate) if (AMEPredicateMatches(p, version)) return YES;
        return [(NSArray *)predicate count] == 0;
    }
    if (![predicate isKindOfClass:NSString.class]) return YES;
    for (NSString *term in [predicate componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) {
        if (term.length && !AMETermMatches(term, version)) return NO;
    }
    return YES;
}

static NSString *AMEDescribePredicate(id predicate) {
    if ([predicate isKindOfClass:NSArray.class]) return [(NSArray *)predicate componentsJoinedByString:@" or "];
    return [predicate description];
}

#pragma mark - Scan

@implementation AMEModCompatibility

+ (NSArray<AMEModInfo *> *)modsInFolder:(NSString *)folder {
    NSMutableArray *mods = [NSMutableArray array];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:folder error:nil]) {
        if (![name.lowercaseString hasSuffix:@".jar"]) continue;   // .jar.disabled is skipped
        NSString *path = [folder stringByAppendingPathComponent:name];
        UZKArchive *archive = [[UZKArchive alloc] initWithPath:path error:nil];
        NSData *data = [archive extractDataFromFile:@"fabric.mod.json" error:nil];
        if (!data) continue;
        // fabric.mod.json sometimes contains raw newlines inside strings; be lenient.
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        text = [[text stringByReplacingOccurrencesOfString:@"\n" withString:@" "] stringByReplacingOccurrencesOfString:@"\t" withString:@" "];
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if (![json isKindOfClass:NSDictionary.class] || ![json[@"id"] isKindOfClass:NSString.class]) continue;
        AMEModInfo *m = [[AMEModInfo alloc] init];
        m.modId = json[@"id"];
        m.name = [json[@"name"] isKindOfClass:NSString.class] ? json[@"name"] : m.modId;
        m.version = [json[@"version"] description] ?: @"";
        m.path = path;
        m.provides = [json[@"provides"] isKindOfClass:NSArray.class] ? json[@"provides"] : @[];
        m.depends = [json[@"depends"] isKindOfClass:NSDictionary.class] ? json[@"depends"] : @{};
        m.breaks = [json[@"breaks"] isKindOfClass:NSDictionary.class] ? json[@"breaks"] : @{};
        [mods addObject:m];
    }
    return mods;
}

+ (NSArray<AMEModConflict *> *)conflictsInModsFolder:(NSString *)modsFolder {
    NSArray<AMEModInfo *> *mods = [self modsInFolder:modsFolder];
    NSMutableDictionary<NSString *, AMEModInfo *> *byId = [NSMutableDictionary dictionary];
    for (AMEModInfo *m in mods) {
        byId[m.modId] = m;
        for (NSString *p in m.provides) if ([p isKindOfClass:NSString.class] && !byId[p]) byId[p] = m;
    }

    NSMutableArray<AMEModConflict *> *conflicts = [NSMutableArray array];
    for (AMEModInfo *m in mods) {
        [m.depends enumerateKeysAndObjectsUsingBlock:^(NSString *depId, id predicate, BOOL *stop) {
            AMEModInfo *dep = byId[depId];
            if (!dep || dep == m) return;   // missing deps aren't judged (nested jars provide many ids)
            if (AMEPredicateMatches(predicate, dep.version)) return;
            AMEModConflict *c = [[AMEModConflict alloc] init];
            c.message = [NSString stringWithFormat:@"%@ needs %@ %@, but %@ is installed.",
                         m.name, dep.name, AMEDescribePredicate(predicate), dep.version];
            c.disableName = m.name;
            c.disablePath = m.path;
            [conflicts addObject:c];
        }];
        [m.breaks enumerateKeysAndObjectsUsingBlock:^(NSString *targetId, id predicate, BOOL *stop) {
            AMEModInfo *target = byId[targetId];
            if (!target || target == m) return;
            if (!AMEPredicateMatches(predicate, target.version)) return;
            AMEModConflict *c = [[AMEModConflict alloc] init];
            c.message = [NSString stringWithFormat:@"%@ doesn't work with %@ %@.", m.name, target.name, target.version];
            c.disableName = target.name;
            c.disablePath = target.path;
            [conflicts addObject:c];
        }];
    }
    return conflicts;
}

+ (void)checkProfile:(NSString *)profileName presenter:(UIViewController *)presenter play:(void (^)(void))play {
    AMEInstanceInfo *info = [AMEInstanceInfo infoForProfileName:profileName];
    if (!info || !([info.loader isEqualToString:@"fabric"] || [info.loader isEqualToString:@"quilt"])) {
        play();
        return;
    }
    NSString *folder = [info folderForKind:AMEModrinthKindMod];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<AMEModConflict *> *conflicts = [self conflictsInModsFolder:folder];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (conflicts.count == 0) { play(); return; }
            AMEModConflict *first = conflicts.firstObject;
            NSMutableArray *lines = [NSMutableArray array];
            for (AMEModConflict *c in conflicts) if (![lines containsObject:c.message]) [lines addObject:c.message];
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Some mods don't work together"
                                                                       message:[[lines componentsJoinedByString:@"\n\n"] stringByAppendingString:@"\n\nThe game would close right after starting."]
                                                                preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Turn off %@ and Play", first.disableName]
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
                [NSFileManager.defaultManager moveItemAtPath:first.disablePath
                                                      toPath:[first.disablePath stringByAppendingString:@".disabled"] error:nil];
                // There may be more; check again.
                [self checkProfile:profileName presenter:presenter play:play];
            }]];
            [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
            [presenter presentViewController:a animated:YES completion:nil];
        });
    });
}

@end
