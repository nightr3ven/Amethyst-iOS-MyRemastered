//
//  AMEInstancesViewController.m
//

#import "AMEModCompatibility.h"
#import "AMEInstanceSettingsViewController.h"
#import "AMEInstancesViewController.h"
#import "AMEDesign.h"
#import "AmeRootTabController.h"
#import "LauncherRightPanelViewController.h"
#import "PLProfiles.h"
#import "ProfileSettingsViewController.h"
#import "ModsManagerViewController.h"
#import "AMEModsViewController.h"
#import "AMEPacksViewController.h"
#import "AMEWorldsViewController.h"
#import "ShadersManagerViewController.h"
#import "ResourcePacksManagerViewController.h"
#import "DataPacksManagerViewController.h"
#import "WorldsManagerViewController.h"
#import "utils.h"
#import "AMENewInstanceViewController.h"
#import "AMEModBrowserViewController.h"

#pragma mark - Shared helpers

NSString *AMEInstanceLoaderName(NSString *versionId) {
    NSString *v = versionId.lowercaseString ?: @"";
    if ([v containsString:@"neoforge"]) return @"NeoForge";
    if ([v containsString:@"forge"]) return @"Forge";
    if ([v containsString:@"fabric"]) return @"Fabric";
    if ([v containsString:@"quilt"]) return @"Quilt";
    if ([v containsString:@"optifine"]) return @"OptiFine";
    return @"Vanilla";
}

UIColor *AMEInstanceLoaderColor(NSString *versionId) {
    NSString *loader = AMEInstanceLoaderName(versionId);
    if ([loader isEqualToString:@"Fabric"])   return UIColor.systemBrownColor;
    if ([loader isEqualToString:@"Quilt"])    return UIColor.systemPurpleColor;
    if ([loader isEqualToString:@"NeoForge"]) return UIColor.systemOrangeColor;
    if ([loader isEqualToString:@"Forge"])    return UIColor.systemRedColor;
    if ([loader isEqualToString:@"OptiFine"]) return UIColor.systemIndigoColor;
    return AMEDesign.accentColor;
}

void AMESelectInstance(NSString *profileName) {
    if (profileName.length == 0) return;
    if ([PLProfiles.current.selectedProfileName isEqualToString:profileName]) return;
    PLProfiles.current.selectedProfileName = profileName;
    [PLProfiles.current save];
    [NSNotificationCenter.defaultCenter postNotificationName:@"SelectedProfileChanged" object:nil];
}

static NSString *AMEVersionIdForProfile(NSString *profileName) {
    NSDictionary *profile = PLProfiles.current.profiles[profileName];
    NSString *v = profile[@"lastVersionId"];
    return [v isKindOfClass:NSString.class] ? v : @"";
}

static NSString *AMEReadableVersion(NSString *versionId) {
    if ([versionId isEqualToString:@"latest-release"]) return @"Latest release";
    if ([versionId isEqualToString:@"latest-snapshot"]) return @"Latest snapshot";
    return versionId.length ? versionId : @"No version";
}

static NSString *AMELastPlayedText(NSString *profileName) {
    id raw = PLProfiles.current.profiles[profileName][@"lastPlayed"];
    double t = [raw respondsToSelector:@selector(doubleValue)] ? [raw doubleValue] : 0;
    if (t <= 0) return @"Never played";
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:t];
    NSRelativeDateTimeFormatter *f = [[NSRelativeDateTimeFormatter alloc] init];
    f.unitsStyle = NSRelativeDateTimeFormatterUnitsStyleFull;
    return [NSString stringWithFormat:@"Played %@", [f localizedStringForDate:date relativeToDate:NSDate.date]];
}

static BOOL AMEProfileHasOwnFolder(NSString *profileName) {
    NSString *gameDir = PLProfiles.current.profiles[profileName][@"gameDir"];
    return [gameDir isKindOfClass:NSString.class] && gameDir.length > 0 && ![gameDir isEqualToString:@"."];
}

static BOOL AMEVersionIsConcrete(NSString *versionId) {
    return versionId.length > 0 && ![versionId hasPrefix:@"latest-"];
}

static void AMEConfirmDelete(UIViewController *host, NSString *profileName, void (^done)(void)) {
    if (PLProfiles.current.profiles.count <= 1) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Can't delete the last instance"
                                                                   message:@"Create another instance first."
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [host presentViewController:a animated:YES completion:nil];
        return;
    }
    UIAlertController *confirm = [UIAlertController
        alertControllerWithTitle:[NSString stringWithFormat:@"Delete “%@”?", profileName]
                         message:@"This removes the instance from the list. Its downloaded version, mods and worlds stay on your iPhone."
                  preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [PLProfiles.current.profiles removeObjectForKey:profileName];
        if ([PLProfiles.current.selectedProfileName isEqualToString:profileName]) {
            PLProfiles.current.selectedProfileName = PLProfiles.current.profiles.allKeys.firstObject;
        }
        [PLProfiles.current save];
        [NSNotificationCenter.defaultCenter postNotificationName:@"SelectedProfileChanged" object:nil];
        if (done) done();
    }]];
    [host presentViewController:confirm animated:YES completion:nil];
}

#pragma mark - Instances list

@interface AMEInstancesViewController ()
@property(nonatomic, copy) NSArray<NSString *> *profileNames;
@end

@implementation AMEInstancesViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Instances";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    self.view.tintColor = AMEDesign.accentColor;
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.tableView.cellLayoutMarginsFollowReadableWidth = YES;

    UIBarButtonItem *add = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                         target:self action:@selector(addInstance)];
    add.accessibilityLabel = @"New instance";
    self.navigationItem.rightBarButtonItem = add;

    for (NSString *name in @[@"SelectedProfileChanged", @"ReloadProfileList"]) {
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reload) name:name object:nil];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    [self reload];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)reload {
    NSDictionary *profiles = PLProfiles.current.profiles;
    // Most recently played first, then by name.
    self.profileNames = [profiles.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        double ta = [profiles[a][@"lastPlayed"] doubleValue], tb = [profiles[b][@"lastPlayed"] doubleValue];
        if (ta != tb) return ta > tb ? NSOrderedAscending : NSOrderedDescending;
        return [a localizedCaseInsensitiveCompare:b];
    }];
    [self.tableView reloadData];
}

- (void)addInstance {
    AMENewInstanceViewController *vc = [[AMENewInstanceViewController alloc] init];
    __weak typeof(self) weakSelf = self;
    vc.onCreated = ^(NSString *name) {
        [weakSelf.navigationController popToViewController:weakSelf animated:NO];
        [weakSelf reload];
        [weakSelf openInstance:name];
    };
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openInstance:(NSString *)name {
    AMEInstanceViewController *vc = [[AMEInstanceViewController alloc] initWithProfileName:name];
    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.profileNames.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"Tap + to create an instance. Each one keeps its own mods, worlds and settings.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"instance"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"instance"];
    NSString *name = self.profileNames[indexPath.row];
    NSString *version = AMEVersionIdForProfile(name);
    BOOL selected = [name isEqualToString:PLProfiles.current.selectedProfileName];

    cell.textLabel.text = name;
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    NSString *detail = [NSString stringWithFormat:@"%@ · %@ · %@",
                        AMEInstanceLoaderName(version), AMEReadableVersion(version), AMELastPlayedText(name)];
    cell.detailTextLabel.text = selected ? [@"Selected · " stringByAppendingString:detail] : detail;
    cell.detailTextLabel.textColor = selected ? AMEDesign.accentColor : UIColor.secondaryLabelColor;
    cell.detailTextLabel.numberOfLines = 2;
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    cell.imageView.image = [AMEDesign iconTileWithSymbol:@"cube.fill" color:AMEInstanceLoaderColor(version)];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self openInstance:self.profileNames[indexPath.row]];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *name = self.profileNames[indexPath.row];
    __weak typeof(self) weakSelf = self;
    UIContextualAction *delete = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                         title:@"Delete"
                                                                       handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        AMEConfirmDelete(weakSelf, name, ^{ [weakSelf reload]; });
        done(YES);
    }];
    delete.image = [UIImage systemImageNamed:@"trash"];
    return [UISwipeActionsConfiguration configurationWithActions:@[delete]];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *name = self.profileNames[indexPath.row];
    if ([name isEqualToString:PLProfiles.current.selectedProfileName]) return nil;
    UIContextualAction *select = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                         title:@"Select"
                                                                       handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        AMESelectInstance(name);
        done(YES);
    }];
    select.backgroundColor = AMEDesign.accentColor;
    select.image = [UIImage systemImageNamed:@"checkmark.circle.fill"];
    return [UISwipeActionsConfiguration configurationWithActions:@[select]];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    NSString *name = self.profileNames[indexPath.row];
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        UIAction *play = [UIAction actionWithTitle:@"Play" image:[UIImage systemImageNamed:@"play.fill"] identifier:nil handler:^(UIAction *a) {
            AMESelectInstance(name);
            [AMEModCompatibility checkProfile:name presenter:weakSelf play:^{
                [LauncherRightPanelViewController norightPostAction:@"launch"];
            }];
        }];
        UIAction *select = [UIAction actionWithTitle:@"Select" image:[UIImage systemImageNamed:@"checkmark.circle"] identifier:nil handler:^(UIAction *a) {
            AMESelectInstance(name);
        }];
        UIAction *settings = [UIAction actionWithTitle:@"Settings" image:[UIImage systemImageNamed:@"slider.horizontal.3"] identifier:nil handler:^(UIAction *a) {
            AMEInstanceSettingsViewController *vc = [[AMEInstanceSettingsViewController alloc] initWithProfileName:name];
            [weakSelf.navigationController pushViewController:vc animated:YES];
        }];
        UIAction *delete = [UIAction actionWithTitle:@"Delete" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *a) {
            AMEConfirmDelete(weakSelf, name, ^{ [weakSelf reload]; });
        }];
        delete.attributes = UIMenuElementAttributesDestructive;
        return [UIMenu menuWithTitle:name children:@[play, select, settings, delete]];
    }];
}

@end

#pragma mark - Single instance

typedef NS_ENUM(NSInteger, AMEInstanceSection) {
    AMEInstanceSectionPlay,
    AMEInstanceSectionContent,
    AMEInstanceSectionSettings,
    AMEInstanceSectionDelete,
    AMEInstanceSectionCount,
};

@interface AMEInstanceViewController ()
@property(nonatomic, copy) NSString *profileName;
@property(nonatomic, strong) UISwitch *isolationSwitch;
@end

@implementation AMEInstanceViewController

- (instancetype)initWithProfileName:(NSString *)profileName {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) _profileName = [profileName copy];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.profileName;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.view.tintColor = AMEDesign.accentColor;
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.tableView.cellLayoutMarginsFollowReadableWidth = YES;

    self.isolationSwitch = [[UISwitch alloc] init];
    self.isolationSwitch.onTintColor = AMEDesign.accentColor;
    [self.isolationSwitch addTarget:self action:@selector(isolationChanged:) forControlEvents:UIControlEventValueChanged];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reload)
                                               name:@"SelectedProfileChanged" object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)reload {
    if (!PLProfiles.current.profiles[self.profileName]) {
        // Deleted (or renamed) elsewhere.
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }
    [self.tableView reloadData];
}

- (NSString *)versionId {
    return AMEVersionIdForProfile(self.profileName);
}

- (BOOL)isSelected {
    return [self.profileName isEqualToString:PLProfiles.current.selectedProfileName];
}

#pragma mark Actions

- (void)play {
    AMESelectInstance(self.profileName);
    [AMEModCompatibility checkProfile:self.profileName presenter:self play:^{
        [LauncherRightPanelViewController norightPostAction:@"launch"];
    }];
}

- (void)isolationChanged:(UISwitch *)sender {
    NSMutableDictionary *profile = PLProfiles.current.profiles[self.profileName];
    if (!profile) return;
    profile[@"versionIsolation"] = sender.on ? @"1" : @"0";
    [PLProfiles.current save];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:AMEInstanceSectionSettings]
                  withRowAnimation:UITableViewRowAnimationNone];
}

- (void)openContent:(NSInteger)row {
    UIViewController *vc = nil;
    switch (row) {
        case 0: {
            vc = [[AMEModsViewController alloc] initWithProfileName:self.profileName];
            break;
        }
        case 1: {
            vc = [[AMEPacksViewController alloc] initWithProfileName:self.profileName kind:AMEModrinthKindShader];
            break;
        }
        case 2: {
            vc = [[AMEPacksViewController alloc] initWithProfileName:self.profileName kind:AMEModrinthKindResourcePack];
            break;
        }
        case 3:
            vc = [[AMEWorldsViewController alloc] initWithProfileName:self.profileName];
            break;
    }
    if (!vc) return;
    // The managers act on the selected instance in a few places, so select it.
    AMESelectInstance(self.profileName);
    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return AMEInstanceSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch ((AMEInstanceSection)section) {
        case AMEInstanceSectionPlay:     return 1;
        case AMEInstanceSectionContent:  return 5;
        case AMEInstanceSectionSettings: return 2;
        case AMEInstanceSectionDelete:   return 1;
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch ((AMEInstanceSection)section) {
        case AMEInstanceSectionContent:  return @"Content";
        case AMEInstanceSectionSettings: return @"Settings";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == AMEInstanceSectionPlay) {
        NSString *v = self.versionId;
        return [NSString stringWithFormat:@"%@ · %@ · %@", AMEInstanceLoaderName(v), AMEReadableVersion(v), AMELastPlayedText(self.profileName)];
    }
    if (section == AMEInstanceSectionSettings) {
        if (AMEProfileHasOwnFolder(self.profileName)) {
            return @"This instance has its own folder, so its mods, config, worlds, resource packs and shaders are never shared.";
        }
        if (!AMEVersionIsConcrete(self.versionId)) {
            return @"This instance follows the latest release, so it uses the shared folder. Pick a specific version in Instance settings to give it its own files.";
        }
        BOOL isolated = amePCLVersionIsolationForProfile(PLProfiles.current.profiles[self.profileName], nil);
        return isolated
            ? @"This instance has its own mods, config, worlds, resource packs and shaders."
            : @"This instance shares mods, config and worlds with other instances that also have this turned off.";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];

    switch ((AMEInstanceSection)indexPath.section) {
        case AMEInstanceSectionPlay: {
            UIButton *play = [AMEDesign buttonWithTitle:(self.isSelected ? @"Play" : @"Play this instance")
                                                 symbol:@"play.fill" style:AMEButtonStylePrimary];
            [play addTarget:self action:@selector(play) forControlEvents:UIControlEventTouchUpInside];
            play.translatesAutoresizingMaskIntoConstraints = NO;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.backgroundColor = UIColor.clearColor;
            cell.backgroundConfiguration = nil;
            [cell.contentView addSubview:play];
            [NSLayoutConstraint activateConstraints:@[
                [play.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:4],
                [play.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-4],
                [play.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor],
                [play.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor],
                [play.heightAnchor constraintGreaterThanOrEqualToConstant:56],
            ]];
            break;
        }
        case AMEInstanceSectionContent: {
            if (indexPath.row == 0) {
                cell.textLabel.text = @"Get mods, shaders & packs";
                cell.textLabel.textColor = AMEDesign.accentColor;
                cell.imageView.image = [AMEDesign iconTileWithSymbol:@"magnifyingglass" color:AMEDesign.accentColor];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                break;
            }
            NSArray *rows = @[
                @[@"Mods", @"puzzlepiece.extension.fill", UIColor.systemOrangeColor],
                @[@"Shaders", @"sparkles", UIColor.systemPurpleColor],
                @[@"Resource packs", @"paintpalette.fill", UIColor.systemPinkColor],
                @[@"Worlds & data packs", @"globe.americas.fill", UIColor.systemGreenColor],
            ];
            NSArray *row = rows[indexPath.row - 1];
            cell.textLabel.text = row[0];
            cell.imageView.image = [AMEDesign iconTileWithSymbol:row[1] color:row[2]];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;
        }
        case AMEInstanceSectionSettings: {
            if (indexPath.row == 0) {
                cell.textLabel.text = @"Keep files separate";
                cell.imageView.image = [AMEDesign iconTileWithSymbol:@"square.on.square.dashed" color:UIColor.systemBlueColor];
                NSDictionary *profile = PLProfiles.current.profiles[self.profileName];
                BOOL ownFolder = AMEProfileHasOwnFolder(self.profileName);
                self.isolationSwitch.on = ownFolder || amePCLVersionIsolationForProfile(profile, nil);
                self.isolationSwitch.enabled = !ownFolder && AMEVersionIsConcrete(self.versionId);
                cell.accessoryView = self.isolationSwitch;
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
            } else {
                cell.textLabel.text = @"Instance settings";
                cell.imageView.image = [AMEDesign iconTileWithSymbol:@"slider.horizontal.3" color:UIColor.systemGrayColor];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            }
            break;
        }
        case AMEInstanceSectionDelete: {
            cell.textLabel.text = @"Delete instance";
            cell.textLabel.textColor = UIColor.systemRedColor;
            cell.textLabel.textAlignment = NSTextAlignmentCenter;
            break;
        }
        default: break;
    }
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == AMEInstanceSectionPlay) return NO;
    if (indexPath.section == AMEInstanceSectionSettings && indexPath.row == 0) return NO;
    return YES;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    switch ((AMEInstanceSection)indexPath.section) {
        case AMEInstanceSectionContent:
            if (indexPath.row == 0) {
                AMESelectInstance(self.profileName);
                NSString *loader = [AMEInstanceInfo infoForProfileName:self.profileName].loader;
                AMEModBrowserViewController *b = [[AMEModBrowserViewController alloc] initWithProfileName:self.profileName
                                                                                                     kind:loader ? AMEModrinthKindMod : AMEModrinthKindShader];
                [self.navigationController pushViewController:b animated:YES];
            } else {
                [self openContent:indexPath.row - 1];
            }
            break;
        case AMEInstanceSectionSettings:
            if (indexPath.row == 1) {
                AMEInstanceSettingsViewController *vc = [[AMEInstanceSettingsViewController alloc] initWithProfileName:self.profileName];
                [self.navigationController pushViewController:vc animated:YES];
            }
            break;
        case AMEInstanceSectionDelete: {
            __weak typeof(self) weakSelf = self;
            AMEConfirmDelete(self, self.profileName, ^{
                [weakSelf.navigationController popViewControllerAnimated:YES];
            });
            break;
        }
        default: break;
    }
}

@end
