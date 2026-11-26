//
//  AMEWorldsViewController.m
//

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "AMEWorldsViewController.h"
#import "AMEDesign.h"
#import "AMEModrinth.h"
#import "UZKArchive.h"

static NSString *AMEByteString(unsigned long long bytes) {
    return [NSByteCountFormatter stringFromByteCount:(long long)bytes countStyle:NSByteCountFormatterCountStyleFile];
}

static unsigned long long AMEFolderSize(NSString *path) {
    unsigned long long total = 0;
    NSDirectoryEnumerator *e = [NSFileManager.defaultManager enumeratorAtPath:path];
    for (NSString *sub in e) total += [e.fileAttributes[NSFileSize] unsignedLongLongValue];
    return total;
}

#pragma mark - Data packs for one world

@interface AMEWorldDataPacksViewController : UITableViewController <UIDocumentPickerDelegate>
@property(nonatomic, copy) NSString *worldPath, *worldName;
@property(nonatomic) NSArray<NSString *> *packs;
@end

@implementation AMEWorldDataPacksViewController

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (NSString *)folder { return [self.worldPath stringByAppendingPathComponent:@"datapacks"]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Data packs";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"plus"] style:UIBarButtonItemStylePlain target:self action:@selector(import)];
    self.navigationItem.rightBarButtonItem.accessibilityLabel = @"Add data pack";
    [self reload];
}

- (void)reload {
    NSMutableArray *a = [NSMutableArray array];
    for (NSString *n in [NSFileManager.defaultManager contentsOfDirectoryAtPath:self.folder error:nil]) {
        if (![n hasPrefix:@"."]) [a addObject:n];
    }
    self.packs = [a sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    [self.tableView reloadData];
}

- (void)import {
    UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeZIP] asCopy:YES];
    p.allowsMultipleSelection = YES;
    p.delegate = self;
    [self presentViewController:p animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    [NSFileManager.defaultManager createDirectoryAtPath:self.folder withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSURL *u in urls) {
        NSString *dest = [self.folder stringByAppendingPathComponent:u.lastPathComponent];
        [NSFileManager.defaultManager removeItemAtPath:dest error:nil];
        [NSFileManager.defaultManager copyItemAtURL:u toURL:[NSURL fileURLWithPath:dest] error:nil];
    }
    [self reload];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return MAX(1, self.packs.count); }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return self.worldName; }

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"Data packs change recipes, loot and world generation for this world only. They load the next time you open the world. Download them as .zip from Modrinth or other sites, then add them with +.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    UIListContentConfiguration *cfg = [UIListContentConfiguration cellConfiguration];
    if (self.packs.count == 0) {
        cfg.text = @"No data packs in this world";
        cfg.textProperties.color = UIColor.secondaryLabelColor;
    } else {
        NSString *n = self.packs[indexPath.row];
        cfg.text = [n.lowercaseString hasSuffix:@".zip"] ? n.stringByDeletingPathExtension : n;
        cfg.image = [AMEDesign iconTileWithSymbol:@"doc.zipper" color:UIColor.systemTealColor];
    }
    cell.contentConfiguration = cfg;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.packs.count == 0) return nil;
    NSString *path = [self.folder stringByAppendingPathComponent:self.packs[indexPath.row]];
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Delete"
        handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
            [NSFileManager.defaultManager removeItemAtPath:path error:nil];
            [self reload];
            done(YES);
        }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}

@end

#pragma mark - Worlds

@interface AMEWorld : NSObject
@property(nonatomic, copy) NSString *path, *name;
@property(nonatomic) NSDate *lastPlayed;
@property(nonatomic) unsigned long long size;
@property(nonatomic, nullable) UIImage *icon;
@property(nonatomic) NSUInteger dataPacks;
@end
@implementation AMEWorld
@end

@interface AMEWorldsViewController () <UIDocumentPickerDelegate>
@property(nonatomic, copy) NSString *profileName;
@property(nonatomic, copy) NSString *savesFolder;
@property(nonatomic) NSArray<AMEWorld *> *worlds;
@property(nonatomic) BOOL loaded;
@end

@implementation AMEWorldsViewController

- (instancetype)initWithProfileName:(NSString *)profileName {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _profileName = [profileName copy];
        _worlds = @[];
        self.title = @"Worlds";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.savesFolder = [[AMEInstanceInfo infoForProfileName:self.profileName].gameDirectory stringByAppendingPathComponent:@"saves"];
    UIBarButtonItem *imp = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"square.and.arrow.down"] style:UIBarButtonItemStylePlain target:self action:@selector(importWorld)];
    imp.accessibilityLabel = @"Import world";
    self.navigationItem.rightBarButtonItem = imp;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
}

- (void)reload {
    NSString *saves = self.savesFolder;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray *worlds = [NSMutableArray array];
        NSFileManager *fm = NSFileManager.defaultManager;
        for (NSString *n in [fm contentsOfDirectoryAtPath:saves error:nil]) {
            NSString *p = [saves stringByAppendingPathComponent:n];
            NSString *level = [p stringByAppendingPathComponent:@"level.dat"];
            if (![fm fileExistsAtPath:level]) continue;
            AMEWorld *w = [[AMEWorld alloc] init];
            w.path = p;
            w.name = n;
            w.lastPlayed = [fm attributesOfItemAtPath:level error:nil][NSFileModificationDate] ?: NSDate.distantPast;
            w.size = AMEFolderSize(p);
            NSData *icon = [NSData dataWithContentsOfFile:[p stringByAppendingPathComponent:@"icon.png"]];
            if (icon) w.icon = [UIImage imageWithData:icon];
            w.dataPacks = [fm contentsOfDirectoryAtPath:[p stringByAppendingPathComponent:@"datapacks"] error:nil].count;
            [worlds addObject:w];
        }
        [worlds sortUsingComparator:^NSComparisonResult(AMEWorld *a, AMEWorld *b) { return [b.lastPlayed compare:a.lastPlayed]; }];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.worlds = worlds;
            self.loaded = YES;
            [self updateEmpty];
            [self.tableView reloadData];
        });
    });
}

- (void)updateEmpty {
    if (!self.loaded || self.worlds.count) { self.tableView.tableHeaderView = nil; return; }
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 200)];
    UILabel *t = [[UILabel alloc] init];
    t.text = @"No worlds yet";
    t.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
    UILabel *s = [[UILabel alloc] init];
    s.text = @"Worlds you create in game show up here. You can also import a world .zip.";
    s.numberOfLines = 0;
    s.textAlignment = NSTextAlignmentCenter;
    s.textColor = UIColor.secondaryLabelColor;
    UIStackView *st = [[UIStackView alloc] initWithArrangedSubviews:@[t, s]];
    st.axis = UILayoutConstraintAxisVertical;
    st.alignment = UIStackViewAlignmentCenter;
    st.spacing = 8;
    st.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:st];
    [NSLayoutConstraint activateConstraints:@[
        [st.centerXAnchor constraintEqualToAnchor:v.centerXAnchor],
        [st.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
        [st.widthAnchor constraintLessThanOrEqualToAnchor:v.widthAnchor constant:-48],
    ]];
    self.tableView.tableHeaderView = v;
}

#pragma mark Actions

- (void)importWorld {
    UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeZIP, UTTypeFolder] asCopy:YES];
    p.delegate = self;
    [self presentViewController:p animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *u = urls.firstObject;
    if (!u) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:self.savesFolder withIntermediateDirectories:YES attributes:nil error:nil];
    BOOL dir = NO;
    [fm fileExistsAtPath:u.path isDirectory:&dir];
    NSString *name = u.lastPathComponent.stringByDeletingPathExtension;
    NSString *dest = [self uniquePathFor:name];
    if (dir) {
        [fm copyItemAtPath:u.path toPath:dest error:nil];
    } else {
        // A world zip usually holds one folder with level.dat inside; flatten it.
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [[[UZKArchive alloc] initWithPath:u.path error:nil] extractFilesTo:tmp overwrite:YES error:nil];
        NSString *root = tmp;
        if (![fm fileExistsAtPath:[tmp stringByAppendingPathComponent:@"level.dat"]]) {
            for (NSString *sub in [fm contentsOfDirectoryAtPath:tmp error:nil]) {
                if ([fm fileExistsAtPath:[[tmp stringByAppendingPathComponent:sub] stringByAppendingPathComponent:@"level.dat"]]) {
                    root = [tmp stringByAppendingPathComponent:sub];
                    break;
                }
            }
        }
        if (![fm fileExistsAtPath:[root stringByAppendingPathComponent:@"level.dat"]]) {
            [fm removeItemAtPath:tmp error:nil];
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"That isn't a Minecraft world"
                message:@"The .zip needs a level.dat file inside." preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:a animated:YES completion:nil];
            return;
        }
        [fm moveItemAtPath:root toPath:dest error:nil];
        [fm removeItemAtPath:tmp error:nil];
    }
    [self reload];
}

- (NSString *)uniquePathFor:(NSString *)name {
    NSString *p = [self.savesFolder stringByAppendingPathComponent:name];
    for (int i = 2; [NSFileManager.defaultManager fileExistsAtPath:p]; i++) {
        p = [self.savesFolder stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ (%d)", name, i]];
    }
    return p;
}

- (void)shareWorld:(AMEWorld *)w from:(UIView *)source {
    NSString *zip = [NSTemporaryDirectory() stringByAppendingPathComponent:[w.name stringByAppendingPathExtension:@"zip"]];
    [NSFileManager.defaultManager removeItemAtPath:zip error:nil];
    UIAlertController *wait = [UIAlertController alertControllerWithTitle:@"Packing world…" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:wait animated:YES completion:nil];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL ok = YES;
        UZKArchive *archive = [[UZKArchive alloc] initWithPath:zip error:nil];
        NSDirectoryEnumerator *e = [NSFileManager.defaultManager enumeratorAtPath:w.path];
        for (NSString *rel in e) {
            if ([e.fileAttributes[NSFileType] isEqualToString:NSFileTypeDirectory]) continue;
            NSData *d = [NSData dataWithContentsOfFile:[w.path stringByAppendingPathComponent:rel] options:NSDataReadingMappedIfSafe error:nil];
            if (!d) continue;
            ok = [archive writeData:d filePath:[w.name stringByAppendingPathComponent:rel] error:nil] && ok;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [wait dismissViewControllerAnimated:YES completion:^{
                if (!ok) return;
                UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:zip]] applicationActivities:nil];
                share.popoverPresentationController.sourceView = source;
                share.popoverPresentationController.sourceRect = source.bounds;
                [self presentViewController:share animated:YES completion:nil];
            }];
        });
    });
}

- (void)renameWorld:(AMEWorld *)w {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Rename folder" message:@"This renames the world's folder. The name shown in game is set inside the world." preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t) { t.text = w.name; t.clearButtonMode = UITextFieldViewModeWhileEditing; }];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Rename" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *n = [a.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (n.length == 0 || [n containsString:@"/"] || [n isEqualToString:w.name]) return;
        [NSFileManager.defaultManager moveItemAtPath:w.path toPath:[self uniquePathFor:n] error:nil];
        [self reload];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)deleteWorld:(AMEWorld *)w {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Delete “%@”?", w.name]
        message:@"This world will be gone for good. Share it first if you want a backup." preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        [NSFileManager.defaultManager removeItemAtPath:w.path error:nil];
        [self reload];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)openDataPacks:(AMEWorld *)w {
    AMEWorldDataPacksViewController *vc = [[AMEWorldDataPacksViewController alloc] init];
    vc.worldPath = w.path;
    vc.worldName = w.name;
    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.worlds.count; }

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return self.worlds.count ? @"Tap a world for its data packs. Press and hold for share, rename and delete." : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    AMEWorld *w = self.worlds[indexPath.row];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    UIListContentConfiguration *cfg = [UIListContentConfiguration subtitleCellConfiguration];
    cfg.text = w.name;
    NSRelativeDateTimeFormatter *f = [[NSRelativeDateTimeFormatter alloc] init];
    NSMutableArray *bits = [NSMutableArray arrayWithObjects:[NSString stringWithFormat:@"Played %@", [f localizedStringForDate:w.lastPlayed relativeToDate:NSDate.date]], AMEByteString(w.size), nil];
    if (w.dataPacks) [bits addObject:[NSString stringWithFormat:@"%lu data pack%@", (unsigned long)w.dataPacks, w.dataPacks == 1 ? @"" : @"s"]];
    cfg.secondaryText = [bits componentsJoinedByString:@" · "];
    cfg.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    cfg.image = w.icon ?: [AMEDesign iconTileWithSymbol:@"globe.americas.fill" color:UIColor.systemGreenColor];
    cfg.imageProperties.maximumSize = CGSizeMake(44, 44);
    cfg.imageProperties.reservedLayoutSize = CGSizeMake(44, 44);
    cfg.imageProperties.cornerRadius = 8;
    cell.contentConfiguration = cfg;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self openDataPacks:self.worlds[indexPath.row]];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    AMEWorld *w = self.worlds[indexPath.row];
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Delete"
        handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) { [self deleteWorld:w]; done(NO); }];
    del.image = [UIImage systemImageNamed:@"trash"];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    AMEWorld *w = self.worlds[indexPath.row];
    UIView *cell = [tableView cellForRowAtIndexPath:indexPath];
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray *s) {
        UIAction *del = [UIAction actionWithTitle:@"Delete" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *a) { [self deleteWorld:w]; }];
        del.attributes = UIMenuElementAttributesDestructive;
        return [UIMenu menuWithChildren:@[
            [UIAction actionWithTitle:@"Data packs" image:[UIImage systemImageNamed:@"doc.zipper"] identifier:nil handler:^(UIAction *a) { [self openDataPacks:w]; }],
            [UIAction actionWithTitle:@"Share / back up" image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(UIAction *a) { [self shareWorld:w from:cell]; }],
            [UIAction actionWithTitle:@"Rename folder" image:[UIImage systemImageNamed:@"pencil"] identifier:nil handler:^(UIAction *a) { [self renameWorld:w]; }],
            del,
        ]];
    }];
}

@end
