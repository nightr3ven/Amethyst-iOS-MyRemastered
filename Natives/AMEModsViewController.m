//
//  AMEModsViewController.m
//

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "AMEModsViewController.h"
#import "AMEDesign.h"
#import "AMEModBrowserViewController.h"
#import "AMEModCompatibility.h"
#import "AMEModrinth.h"
#import "ModItem.h"
#import "ModService.h"
#import "ModsManagerViewController.h"

typedef NS_ENUM(NSInteger, AMEModsSection) {
    AMEModsSectionProblems,
    AMEModsSectionMods,
    AMEModsSectionCount,
};

@interface AMEModsViewController () <UISearchResultsUpdating, UIDocumentPickerDelegate>
@property(nonatomic, copy) NSString *profileName;
@property(nonatomic) NSArray<ModItem *> *mods;
@property(nonatomic) NSArray<ModItem *> *shown;
@property(nonatomic) NSArray<AMEModConflict *> *conflicts;
@property(nonatomic, copy) NSString *filter;
@property(nonatomic) BOOL loaded;
@end

@implementation AMEModsViewController

- (instancetype)initWithProfileName:(NSString *)profileName {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _profileName = [profileName copy];
        _mods = @[];
        _shown = @[];
        _conflicts = @[];
        self.title = @"Mods";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 64;

    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = @"Search installed mods";
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = YES;

    UIBarButtonItem *get = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"plus"] style:UIBarButtonItemStylePlain target:self action:@selector(getMods)];
    get.accessibilityLabel = @"Get mods";
    __weak typeof(self) ws = self;
    UIMenu *more = [UIMenu menuWithChildren:@[
        [UIAction actionWithTitle:@"Import .jar from Files" image:[UIImage systemImageNamed:@"square.and.arrow.down"] identifier:nil handler:^(UIAction *a) { [ws importFromFiles]; }],
        [UIAction actionWithTitle:@"Check for updates" image:[UIImage systemImageNamed:@"arrow.triangle.2.circlepath"] identifier:nil handler:^(UIAction *a) { [ws openUpdates]; }],
        [UIAction actionWithTitle:@"Turn all on" image:[UIImage systemImageNamed:@"checkmark.circle"] identifier:nil handler:^(UIAction *a) { [ws setAllEnabled:YES]; }],
    ]];
    UIBarButtonItem *menu = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:more];
    menu.accessibilityLabel = @"More";
    self.navigationItem.rightBarButtonItems = @[get, menu];

    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
}

- (NSString *)modsFolder {
    return [[AMEInstanceInfo infoForProfileName:self.profileName] folderForKind:AMEModrinthKindMod];
}

- (void)reload {
    __weak typeof(self) ws = self;
    [[ModService sharedService] scanModsForProfile:self.profileName completion:^(NSArray<ModItem *> *mods) {
        NSString *folder = [ws modsFolder];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSArray *conflicts = folder ? [AMEModCompatibility conflictsInModsFolder:folder] : @[];
            dispatch_async(dispatch_get_main_queue(), ^{
                ws.mods = [mods sortedArrayUsingComparator:^NSComparisonResult(ModItem *a, ModItem *b) {
                    return [[ws nameOf:a] localizedCaseInsensitiveCompare:[ws nameOf:b]];
                }];
                // Same message can come from both sides of a conflict; show it once.
                NSMutableArray *unique = [NSMutableArray array];
                NSMutableSet *seen = [NSMutableSet set];
                for (AMEModConflict *c in conflicts) if (![seen containsObject:c.message]) { [seen addObject:c.message]; [unique addObject:c]; }
                ws.conflicts = unique;
                ws.loaded = YES;
                [ws applyFilter];
                [ws.refreshControl endRefreshing];
            });
        });
    }];
}

- (NSString *)nameOf:(ModItem *)m {
    NSString *n = m.displayName.length ? m.displayName : [m basename];
    return n ?: m.fileName ?: @"Mod";
}

- (void)applyFilter {
    if (self.filter.length) {
        NSMutableArray *a = [NSMutableArray array];
        for (ModItem *m in self.mods) {
            if ([[self nameOf:m] localizedCaseInsensitiveContainsString:self.filter] ||
                [m.fileName localizedCaseInsensitiveContainsString:self.filter]) [a addObject:m];
        }
        self.shown = a;
    } else {
        self.shown = self.mods;
    }
    [self updateHeader];
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    self.filter = searchController.searchBar.text;
    [self applyFilter];
}

- (void)updateHeader {
    if (!self.loaded) return;
    if (self.mods.count == 0) {
        UIView *empty = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 260)];
        UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"puzzlepiece.extension"]];
        icon.tintColor = UIColor.tertiaryLabelColor;
        icon.contentMode = UIViewContentModeScaleAspectFit;
        UILabel *title = [[UILabel alloc] init];
        title.text = @"No mods yet";
        title.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
        UILabel *sub = [[UILabel alloc] init];
        sub.text = @"Find mods on Modrinth and they'll install straight into this instance.";
        sub.textColor = UIColor.secondaryLabelColor;
        sub.numberOfLines = 0;
        sub.textAlignment = NSTextAlignmentCenter;
        UIButton *get = [AMEDesign buttonWithTitle:@"Get mods" symbol:@"plus" style:AMEButtonStylePrimary];
        [get addTarget:self action:@selector(getMods) forControlEvents:UIControlEventTouchUpInside];
        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[icon, title, sub, get]];
        stack.axis = UILayoutConstraintAxisVertical;
        stack.alignment = UIStackViewAlignmentCenter;
        stack.spacing = 10;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [empty addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [icon.heightAnchor constraintEqualToConstant:52], [icon.widthAnchor constraintEqualToConstant:52],
            [stack.centerXAnchor constraintEqualToAnchor:empty.centerXAnchor],
            [stack.centerYAnchor constraintEqualToAnchor:empty.centerYAnchor],
            [stack.widthAnchor constraintLessThanOrEqualToAnchor:empty.widthAnchor constant:-48],
        ]];
        self.tableView.tableHeaderView = empty;
    } else {
        self.tableView.tableHeaderView = nil;
    }
}

#pragma mark Actions

- (void)getMods {
    AMEModBrowserViewController *vc = [[AMEModBrowserViewController alloc] initWithProfileName:self.profileName kind:AMEModrinthKindMod];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openUpdates {
    ModsManagerViewController *m = [[ModsManagerViewController alloc] init];
    m.profileName = self.profileName;
    [self.navigationController pushViewController:m animated:YES];
}

- (void)importFromFiles {
    UTType *jar = [UTType typeWithFilenameExtension:@"jar"] ?: UTTypeData;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[jar] asCopy:YES];
    picker.allowsMultipleSelection = YES;
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSString *folder = [self modsFolder];
    if (!folder) return;
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSURL *url in urls) {
        NSString *dest = [folder stringByAppendingPathComponent:url.lastPathComponent];
        [NSFileManager.defaultManager removeItemAtPath:dest error:nil];
        [NSFileManager.defaultManager copyItemAtURL:url toURL:[NSURL fileURLWithPath:dest] error:nil];
    }
    [self reload];
}

- (void)setAllEnabled:(BOOL)enabled {
    for (ModItem *m in self.mods) {
        if (m.disabled == enabled) [[ModService sharedService] toggleEnableForMod:m error:nil];
    }
    [self reload];
}

- (void)toggle:(UISwitch *)sw {
    if (sw.tag < 0 || sw.tag >= (NSInteger)self.shown.count) return;
    ModItem *m = self.shown[sw.tag];
    NSError *error;
    if (![[ModService sharedService] toggleEnableForMod:m error:&error]) {
        sw.on = !m.disabled;
        return;
    }
    // Re-check conflicts and the dimmed state without losing scroll position.
    [self reload];
}

- (void)fixConflict:(AMEModConflict *)c {
    [NSFileManager.defaultManager moveItemAtPath:c.disablePath toPath:[c.disablePath stringByAppendingString:@".disabled"] error:nil];
    [self reload];
}

- (void)deleteMod:(ModItem *)m {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Delete %@?", [self nameOf:m]]
        message:@"The file is removed from this instance." preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        [[ModService sharedService] deleteMod:m error:nil];
        [self reload];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return AMEModsSectionCount; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == AMEModsSectionProblems) return self.filter.length ? 0 : self.conflicts.count;
    return self.shown.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == AMEModsSectionProblems) return (self.conflicts.count && !self.filter.length) ? @"Needs attention" : nil;
    if (self.mods.count == 0) return nil;
    NSUInteger on = 0;
    for (ModItem *m in self.mods) if (!m.disabled) on++;
    return self.filter.length ? [NSString stringWithFormat:@"%lu results", (unsigned long)self.shown.count]
                              : [NSString stringWithFormat:@"%lu installed · %lu on", (unsigned long)self.mods.count, (unsigned long)on];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == AMEModsSectionMods && self.mods.count) return @"Turned-off mods stay installed but don't load. Swipe left to delete.";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == AMEModsSectionProblems) {
        AMEModConflict *c = self.conflicts[indexPath.row];
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        UIListContentConfiguration *cfg = [UIListContentConfiguration subtitleCellConfiguration];
        cfg.image = [UIImage systemImageNamed:@"exclamationmark.triangle.fill"];
        cfg.imageProperties.tintColor = UIColor.systemOrangeColor;
        cfg.text = c.message;
        cfg.textProperties.numberOfLines = 0;
        cfg.secondaryText = [NSString stringWithFormat:@"Tap to turn off %@", c.disableName];
        cfg.secondaryTextProperties.color = AMEDesign.accentColor;
        cell.contentConfiguration = cfg;
        return cell;
    }

    ModItem *m = self.shown[indexPath.row];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"mod"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"mod"];
    UIListContentConfiguration *cfg = [UIListContentConfiguration subtitleCellConfiguration];
    cfg.text = [self nameOf:m];
    NSMutableArray *bits = [NSMutableArray array];
    if (m.version.length && ![m.version containsString:@"${"]) [bits addObject:m.version];
    if (m.isForge || m.isNeoForge) [bits addObject:m.isForge ? @"Forge mod (won't load here)" : @"NeoForge mod (won't load here)"];
    else if (m.modDescription.length) [bits addObject:m.modDescription];
    cfg.secondaryText = [bits componentsJoinedByString:@" · "];
    cfg.secondaryTextProperties.numberOfLines = 2;
    cfg.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    cfg.image = m.icon ?: [AMEDesign iconTileWithSymbol:@"puzzlepiece.extension.fill" color:UIColor.systemGrayColor];
    cfg.imageProperties.maximumSize = CGSizeMake(40, 40);
    cfg.imageProperties.reservedLayoutSize = CGSizeMake(40, 40);
    cfg.imageProperties.cornerRadius = 9;
    cfg.textProperties.color = m.disabled ? UIColor.secondaryLabelColor : UIColor.labelColor;
    cell.contentConfiguration = cfg;
    cell.contentView.alpha = m.disabled ? 0.55 : 1;

    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = !m.disabled;
    sw.tag = indexPath.row;
    sw.accessibilityLabel = [NSString stringWithFormat:@"%@ on", [self nameOf:m]];
    [sw addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == AMEModsSectionProblems) [self fixConflict:self.conflicts[indexPath.row]];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != AMEModsSectionMods) return nil;
    ModItem *m = self.shown[indexPath.row];
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Delete"
        handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) { [self deleteMod:m]; done(NO); }];
    del.image = [UIImage systemImageNamed:@"trash"];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    if (indexPath.section != AMEModsSectionMods) return nil;
    ModItem *m = self.shown[indexPath.row];
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray *s) {
        NSMutableArray *items = [NSMutableArray array];
        [items addObject:[UIAction actionWithTitle:m.disabled ? @"Turn on" : @"Turn off" image:[UIImage systemImageNamed:m.disabled ? @"power" : @"poweroff"] identifier:nil handler:^(UIAction *a) {
            [[ModService sharedService] toggleEnableForMod:m error:nil];
            [self reload];
        }]];
        if (m.homepage.length) {
            [items addObject:[UIAction actionWithTitle:@"Open website" image:[UIImage systemImageNamed:@"safari"] identifier:nil handler:^(UIAction *a) {
                NSURL *u = [NSURL URLWithString:m.homepage];
                if (u) [UIApplication.sharedApplication openURL:u options:@{} completionHandler:nil];
            }]];
        }
        UIAction *del = [UIAction actionWithTitle:@"Delete" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *a) { [self deleteMod:m]; }];
        del.attributes = UIMenuElementAttributesDestructive;
        [items addObject:del];
        return [UIMenu menuWithChildren:items];
    }];
}

@end
