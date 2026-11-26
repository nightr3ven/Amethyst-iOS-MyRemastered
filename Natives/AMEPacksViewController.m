//
//  AMEPacksViewController.m
//

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "AMEPacksViewController.h"
#import "AMEDesign.h"
#import "AMEModBrowserViewController.h"
#import "UZKArchive.h"

@interface AMEPackItem : NSObject
@property(nonatomic, copy) NSString *fileName;   // as on disk
@property(nonatomic, copy) NSString *title;      // without .zip
@property(nonatomic, copy, nullable) NSString *summary;
@property(nonatomic, nullable) UIImage *icon;
@end
@implementation AMEPackItem
@end

@interface AMEPacksViewController () <UIDocumentPickerDelegate>
@property(nonatomic, copy) NSString *profileName;
@property(nonatomic) AMEModrinthKind kind;
@property(nonatomic) NSArray<AMEPackItem *> *items;
@property(nonatomic) NSString *gameDir, *folder;
@property(nonatomic, copy, nullable) NSString *activeShader;      // nil = off
@property(nonatomic) NSMutableArray<NSString *> *enabledPacks;    // options.txt entries
@property(nonatomic) BOOL loaded;
@end

@implementation AMEPacksViewController

- (instancetype)initWithProfileName:(NSString *)profileName kind:(AMEModrinthKind)kind {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _profileName = [profileName copy];
        _kind = kind;
        _items = @[];
        _enabledPacks = [NSMutableArray array];
        self.title = kind == AMEModrinthKindShader ? @"Shaders" : @"Resource packs";
    }
    return self;
}

- (BOOL)isShaders { return self.kind == AMEModrinthKindShader; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    AMEInstanceInfo *info = [AMEInstanceInfo infoForProfileName:self.profileName];
    self.gameDir = info.gameDirectory;
    self.folder = [info folderForKind:self.kind];

    UIBarButtonItem *get = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"plus"] style:UIBarButtonItemStylePlain target:self action:@selector(getMore)];
    get.accessibilityLabel = self.isShaders ? @"Get shaders" : @"Get resource packs";
    __weak typeof(self) ws = self;
    UIBarButtonItem *more = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:
        [UIMenu menuWithChildren:@[[UIAction actionWithTitle:@"Import .zip from Files" image:[UIImage systemImageNamed:@"square.and.arrow.down"] identifier:nil handler:^(UIAction *a) { [ws importFromFiles]; }]]]];
    more.accessibilityLabel = @"More";
    self.navigationItem.rightBarButtonItems = @[get, more];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
}

#pragma mark Data

- (NSString *)irisPath { return [self.gameDir stringByAppendingPathComponent:@"config/iris.properties"]; }
- (NSString *)optionsPath { return [self.gameDir stringByAppendingPathComponent:@"options.txt"]; }

- (void)reload {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray *items = [NSMutableArray array];
        for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:self.folder error:nil]) {
            if ([name hasPrefix:@"."]) continue;
            NSString *path = [self.folder stringByAppendingPathComponent:name];
            BOOL dir = NO;
            [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&dir];
            if (!dir && ![name.lowercaseString hasSuffix:@".zip"]) continue;
            AMEPackItem *it = [[AMEPackItem alloc] init];
            it.fileName = name;
            it.title = [name.lowercaseString hasSuffix:@".zip"] ? name.stringByDeletingPathExtension : name;
            if (!self.isShaders) [self loadPackMeta:it path:path directory:dir];
            [items addObject:it];
        }
        [items sortUsingComparator:^NSComparisonResult(AMEPackItem *a, AMEPackItem *b) { return [a.title localizedCaseInsensitiveCompare:b.title]; }];

        NSString *active = nil;
        NSMutableArray *enabled = [NSMutableArray array];
        if (self.isShaders) {
            NSString *props = [NSString stringWithContentsOfFile:self.irisPath encoding:NSUTF8StringEncoding error:nil];
            BOOL on = YES;
            for (NSString *line in [props componentsSeparatedByString:@"\n"]) {
                if ([line hasPrefix:@"shaderPack="]) active = [[line substringFromIndex:11] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if ([line hasPrefix:@"enableShaders="]) on = [[line substringFromIndex:14] hasPrefix:@"true"];
            }
            if (!on || active.length == 0) active = nil;
        } else {
            NSString *opts = [NSString stringWithContentsOfFile:self.optionsPath encoding:NSUTF8StringEncoding error:nil];
            for (NSString *line in [opts componentsSeparatedByString:@"\n"]) {
                if (![line hasPrefix:@"resourcePacks:"]) continue;
                NSData *json = [[line substringFromIndex:14] dataUsingEncoding:NSUTF8StringEncoding];
                NSArray *arr = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
                if ([arr isKindOfClass:NSArray.class]) [enabled addObjectsFromArray:arr];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.items = items;
            self.activeShader = active;
            self.enabledPacks = enabled;
            self.loaded = YES;
            [self updateEmptyState];
            [self.tableView reloadData];
        });
    });
}

- (void)loadPackMeta:(AMEPackItem *)it path:(NSString *)path directory:(BOOL)dir {
    NSData *png = nil, *meta = nil;
    if (dir) {
        png = [NSData dataWithContentsOfFile:[path stringByAppendingPathComponent:@"pack.png"]];
        meta = [NSData dataWithContentsOfFile:[path stringByAppendingPathComponent:@"pack.mcmeta"]];
    } else {
        UZKArchive *zip = [[UZKArchive alloc] initWithPath:path error:nil];
        png = [zip extractDataFromFile:@"pack.png" error:nil];
        meta = [zip extractDataFromFile:@"pack.mcmeta" error:nil];
    }
    if (png) it.icon = [UIImage imageWithData:png];
    NSDictionary *json = meta ? [NSJSONSerialization JSONObjectWithData:meta options:NSJSONReadingFragmentsAllowed error:nil] : nil;
    id desc = [json isKindOfClass:NSDictionary.class] ? json[@"pack"][@"description"] : nil;
    if ([desc isKindOfClass:NSString.class]) it.summary = desc;
    else if ([desc isKindOfClass:NSDictionary.class] && [desc[@"text"] isKindOfClass:NSString.class]) it.summary = desc[@"text"];
    else if ([desc isKindOfClass:NSArray.class]) {
        NSMutableString *s = [NSMutableString string];
        for (id part in desc) {
            if ([part isKindOfClass:NSString.class]) [s appendString:part];
            else if ([part isKindOfClass:NSDictionary.class] && [part[@"text"] isKindOfClass:NSString.class]) [s appendString:part[@"text"]];
        }
        it.summary = s;
    }
    // Strip Minecraft § color codes.
    if (it.summary) {
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"§." options:0 error:nil];
        it.summary = [re stringByReplacingMatchesInString:it.summary options:0 range:NSMakeRange(0, it.summary.length) withTemplate:@""];
    }
}

- (void)writeShader:(nullable NSString *)fileName {
    NSString *props = [NSString stringWithContentsOfFile:self.irisPath encoding:NSUTF8StringEncoding error:nil] ?: @"";
    NSMutableArray *lines = [NSMutableArray array];
    for (NSString *line in [props componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"shaderPack="] || [line hasPrefix:@"enableShaders="] || line.length == 0) continue;
        [lines addObject:line];
    }
    [lines addObject:[NSString stringWithFormat:@"enableShaders=%@", fileName ? @"true" : @"false"]];
    [lines addObject:[NSString stringWithFormat:@"shaderPack=%@", fileName ?: @""]];
    [NSFileManager.defaultManager createDirectoryAtPath:self.irisPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [[[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"] writeToFile:self.irisPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (void)writeEnabledPacks {
    NSString *opts = [NSString stringWithContentsOfFile:self.optionsPath encoding:NSUTF8StringEncoding error:nil] ?: @"";
    NSMutableArray *lines = [[opts componentsSeparatedByString:@"\n"] mutableCopy];
    NSData *json = [NSJSONSerialization dataWithJSONObject:self.enabledPacks options:0 error:nil];
    NSString *line = [@"resourcePacks:" stringByAppendingString:[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]];
    BOOL replaced = NO;
    for (NSUInteger i = 0; i < lines.count; i++) {
        if ([lines[i] hasPrefix:@"resourcePacks:"]) { lines[i] = line; replaced = YES; }
        // Clear the "incompatible" list so a newly enabled pack isn't skipped.
        else if ([lines[i] hasPrefix:@"incompatibleResourcePacks:"]) lines[i] = @"incompatibleResourcePacks:[]";
    }
    if (!replaced) {
        if (lines.count && [lines.lastObject length] == 0) [lines removeLastObject];
        [lines addObject:line];
        [lines addObject:@""];
    }
    [[lines componentsJoinedByString:@"\n"] writeToFile:self.optionsPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (NSString *)packKey:(AMEPackItem *)it { return [@"file/" stringByAppendingString:it.fileName]; }

#pragma mark Actions

- (void)getMore {
    AMEModBrowserViewController *vc = [[AMEModBrowserViewController alloc] initWithProfileName:self.profileName kind:self.kind];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)importFromFiles {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeZIP] asCopy:YES];
    picker.allowsMultipleSelection = YES;
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    [NSFileManager.defaultManager createDirectoryAtPath:self.folder withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSURL *url in urls) {
        NSString *dest = [self.folder stringByAppendingPathComponent:url.lastPathComponent];
        [NSFileManager.defaultManager removeItemAtPath:dest error:nil];
        [NSFileManager.defaultManager copyItemAtURL:url toURL:[NSURL fileURLWithPath:dest] error:nil];
    }
    [self reload];
}

- (void)togglePack:(UISwitch *)sw {
    if (sw.tag >= (NSInteger)self.items.count) return;
    NSString *key = [self packKey:self.items[sw.tag]];
    [self.enabledPacks removeObject:key];
    // Minecraft lists packs bottom-to-top; append so a new pack goes on top.
    if (sw.isOn) [self.enabledPacks addObject:key];
    [self writeEnabledPacks];
}

- (void)deleteItem:(AMEPackItem *)it {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Delete %@?", it.title]
        message:nil preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        [NSFileManager.defaultManager removeItemAtPath:[self.folder stringByAppendingPathComponent:it.fileName] error:nil];
        if (self.isShaders && [self.activeShader isEqualToString:it.fileName]) [self writeShader:nil];
        if (!self.isShaders && [self.enabledPacks containsObject:[self packKey:it]]) {
            [self.enabledPacks removeObject:[self packKey:it]];
            [self writeEnabledPacks];
        }
        [self reload];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)updateEmptyState {
    if (!self.loaded || self.items.count) { self.tableView.tableHeaderView = nil; return; }
    UIView *empty = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 240)];
    UILabel *title = [[UILabel alloc] init];
    title.text = self.isShaders ? @"No shaders yet" : @"No resource packs yet";
    title.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
    UILabel *sub = [[UILabel alloc] init];
    sub.text = self.isShaders ? @"Shaders need Iris (installed with Fabric). Get one from Modrinth to try it." : @"Change textures, sounds and fonts. Get one from Modrinth to try it.";
    sub.numberOfLines = 0;
    sub.textAlignment = NSTextAlignmentCenter;
    sub.textColor = UIColor.secondaryLabelColor;
    UIButton *get = [AMEDesign buttonWithTitle:self.isShaders ? @"Get shaders" : @"Get resource packs" symbol:@"plus" style:AMEButtonStylePrimary];
    [get addTarget:self action:@selector(getMore) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[title, sub, get]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [empty addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:empty.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:empty.centerYAnchor],
        [stack.widthAnchor constraintLessThanOrEqualToAnchor:empty.widthAnchor constant:-48],
    ]];
    self.tableView.tableHeaderView = empty;
}

#pragma mark Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (!self.items.count) return 0;
    return self.items.count + (self.isShaders ? 1 : 0);   // shaders: "Off" row first
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (!self.items.count) return nil;
    return self.isShaders ? @"Active shader" : [NSString stringWithFormat:@"%lu installed", (unsigned long)self.items.count];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (!self.items.count) return nil;
    return self.isShaders ? @"Shaders are heavy on a phone. If the game stutters, pick Off or lower Shadow distance in the shader's settings."
                          : @"Changes apply the next time the game starts. Swipe left to delete.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    UIListContentConfiguration *cfg = [UIListContentConfiguration subtitleCellConfiguration];
    cfg.imageProperties.maximumSize = CGSizeMake(40, 40);
    cfg.imageProperties.reservedLayoutSize = CGSizeMake(40, 40);
    cfg.imageProperties.cornerRadius = 8;
    cfg.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    cfg.secondaryTextProperties.numberOfLines = 2;
    if (self.isShaders) {
        if (indexPath.row == 0) {
            cfg.text = @"Off";
            cfg.secondaryText = @"Best performance";
            cfg.image = [AMEDesign iconTileWithSymbol:@"sun.min" color:UIColor.systemGrayColor];
            cell.accessoryType = self.activeShader == nil ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        } else {
            AMEPackItem *it = self.items[indexPath.row - 1];
            cfg.text = it.title;
            cfg.image = [AMEDesign iconTileWithSymbol:@"sun.max.fill" color:UIColor.systemOrangeColor];
            cell.accessoryType = [self.activeShader isEqualToString:it.fileName] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        }
    } else {
        AMEPackItem *it = self.items[indexPath.row];
        cfg.text = it.title;
        cfg.secondaryText = it.summary;
        cfg.image = it.icon ?: [AMEDesign iconTileWithSymbol:@"paintpalette.fill" color:UIColor.systemPinkColor];
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = [self.enabledPacks containsObject:[self packKey:it]];
        sw.tag = indexPath.row;
        [sw addTarget:self action:@selector(togglePack:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    cell.contentConfiguration = cfg;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (!self.isShaders) return;
    NSString *pick = indexPath.row == 0 ? nil : self.items[indexPath.row - 1].fileName;
    self.activeShader = pick;
    [self writeShader:pick];
    [tableView reloadData];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.isShaders && indexPath.row == 0) return nil;
    AMEPackItem *it = self.items[indexPath.row - (self.isShaders ? 1 : 0)];
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Delete"
        handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) { [self deleteItem:it]; done(NO); }];
    del.image = [UIImage systemImageNamed:@"trash"];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}

@end
