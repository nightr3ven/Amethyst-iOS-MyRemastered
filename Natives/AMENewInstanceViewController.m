//
//  AMENewInstanceViewController.m
//

#import "AMENewInstanceViewController.h"
#import "AMEDesign.h"
#import "AMEModrinth.h"
#import "AMEInstancesViewController.h"
#import "PLProfiles.h"
#import "utils.h"

typedef NS_ENUM(NSInteger, AMELoader) {
    AMELoaderFabric,
    AMELoaderVanilla,
    AMELoaderQuilt,
};

typedef NS_ENUM(NSInteger, AMENewSection) {
    AMENewSectionName,
    AMENewSectionVersion,
    AMENewSectionLoader,
    AMENewSectionCreate,
    AMENewSectionCount,
};

static NSString *AMELoaderTitle(AMELoader l) {
    switch (l) {
        case AMELoaderFabric:  return @"Fabric";
        case AMELoaderVanilla: return @"Vanilla";
        case AMELoaderQuilt:   return @"Quilt";
    }
    return @"";
}

#pragma mark - Version picker

@interface AMEVersionPickerViewController : UITableViewController <UISearchResultsUpdating>
@property(nonatomic, copy) NSArray<NSDictionary *> *allVersions;   // {id, type}
@property(nonatomic, copy) NSArray<NSDictionary *> *shown;
@property(nonatomic) BOOL showSnapshots;
@property(nonatomic, copy) NSString *selected;
@property(nonatomic, copy) NSString *filter;
@property(nonatomic, copy) void (^onPick)(NSString *version);
@end

@implementation AMEVersionPickerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Minecraft version";
    self.view.tintColor = AMEDesign.accentColor;
    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = @"Search versions";
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Snapshots"
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self action:@selector(toggleSnapshots)];
    [self refilter];
}

- (void)toggleSnapshots {
    self.showSnapshots = !self.showSnapshots;
    self.navigationItem.rightBarButtonItem.style = self.showSnapshots ? UIBarButtonItemStyleDone : UIBarButtonItemStylePlain;
    [self refilter];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)sc {
    self.filter = sc.searchBar.text ?: @"";
    [self refilter];
}

- (void)refilter {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *v in self.allVersions) {
        BOOL release = [v[@"type"] isEqualToString:@"release"];
        if (!release && !self.showSnapshots) continue;
        if (self.filter.length && ![v[@"id"] localizedCaseInsensitiveContainsString:self.filter]) continue;
        [out addObject:v];
    }
    self.shown = out;
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.shown.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"v"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"v"];
    NSDictionary *v = self.shown[indexPath.row];
    cell.textLabel.text = v[@"id"];
    cell.detailTextLabel.text = [v[@"type"] isEqualToString:@"release"] ? nil : @"Snapshot";
    cell.accessoryType = [v[@"id"] isEqualToString:self.selected] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *v = self.shown[indexPath.row][@"id"];
    if (self.onPick) self.onPick(v);
    [self.navigationController popViewControllerAnimated:YES];
}

@end

#pragma mark - New instance

@interface AMENewInstanceViewController () <UITextFieldDelegate>
@property(nonatomic, strong) UITextField *nameField;
@property(nonatomic, strong) UISwitch *fabricAPISwitch;
@property(nonatomic, copy) NSArray<NSDictionary *> *versions;   // Mojang manifest entries
@property(nonatomic, copy) NSSet<NSString *> *fabricGameVersions;
@property(nonatomic, copy) NSString *gameVersion;
@property(nonatomic) AMELoader loader;
@property(nonatomic) BOOL nameEdited;
@property(nonatomic) BOOL creating;
@property(nonatomic, copy, nullable) NSString *status;
@end

@implementation AMENewInstanceViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) _loader = AMELoaderFabric;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"New Instance";
    self.view.tintColor = AMEDesign.accentColor;
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.tableView.cellLayoutMarginsFollowReadableWidth = YES;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;

    self.nameField = [[UITextField alloc] init];
    self.nameField.placeholder = @"Name";
    self.nameField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.nameField.returnKeyType = UIReturnKeyDone;
    self.nameField.autocapitalizationType = UITextAutocapitalizationTypeWords;
    self.nameField.delegate = self;
    [self.nameField addTarget:self action:@selector(nameChanged) forControlEvents:UIControlEventEditingChanged];

    self.fabricAPISwitch = [[UISwitch alloc] init];
    self.fabricAPISwitch.on = YES;
    self.fabricAPISwitch.onTintColor = AMEDesign.accentColor;

    self.status = @"Loading versions…";
    [self loadVersions];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)nameChanged {
    self.nameEdited = self.nameField.text.length > 0;
}

- (void)updateSuggestedName {
    if (self.nameEdited || !self.gameVersion) return;
    self.nameField.text = self.loader == AMELoaderVanilla
        ? [NSString stringWithFormat:@"Minecraft %@", self.gameVersion]
        : [NSString stringWithFormat:@"%@ %@", AMELoaderTitle(self.loader), self.gameVersion];
}

#pragma mark Data

- (void)getJSON:(NSString *)url completion:(void (^)(id json))completion {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    [req setValue:@"Air-iOS-launcher/redesign" forHTTPHeaderField:@"User-Agent"];
    [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(json); });
    }] resume];
}

- (void)loadVersions {
    __weak typeof(self) weakSelf = self;
    [self getJSON:@"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json" completion:^(NSDictionary *json) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        NSArray *versions = [json isKindOfClass:NSDictionary.class] ? json[@"versions"] : nil;
        if (versions.count == 0) {
            self.status = @"Couldn't load versions. Check your connection and try again.";
            [self.tableView reloadData];
            return;
        }
        NSMutableArray *list = [NSMutableArray array];
        for (NSDictionary *v in versions) {
            if ([v[@"type"] isEqualToString:@"release"] || [v[@"type"] isEqualToString:@"snapshot"]) {
                [list addObject:@{@"id": v[@"id"], @"type": v[@"type"]}];
            }
        }
        self.versions = list;
        self.gameVersion = json[@"latest"][@"release"];
        self.status = nil;
        [self updateSuggestedName];
        [self.tableView reloadData];
    }];
    [self getJSON:@"https://meta.fabricmc.net/v2/versions/game" completion:^(NSArray *json) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || ![json isKindOfClass:NSArray.class]) return;
        NSMutableSet *set = [NSMutableSet set];
        for (NSDictionary *v in json) if (v[@"version"]) [set addObject:v[@"version"]];
        self.fabricGameVersions = set;
        [self.tableView reloadData];
    }];
}

- (BOOL)loaderSupportsVersion {
    if (self.loader == AMELoaderVanilla || !self.fabricGameVersions || !self.gameVersion) return YES;
    return [self.fabricGameVersions containsObject:self.gameVersion];   // Quilt follows Fabric closely
}

#pragma mark Create

- (NSString *)uniqueProfileName:(NSString *)base {
    NSString *name = base.length ? base : @"New Instance";
    NSString *candidate = name;
    for (int i = 2; PLProfiles.current.profiles[candidate]; i++) {
        candidate = [NSString stringWithFormat:@"%@ %d", name, i];
    }
    return candidate;
}

- (NSString *)folderNameFor:(NSString *)name {
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/\\:*?\"<>|"];
    NSString *clean = [[name componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"-"];
    clean = [clean stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (clean.length == 0) clean = @"instance";
    NSString *base = [NSString stringWithFormat:@"profiles/%@", clean];
    NSString *root = @(getenv("POJAV_GAME_DIR") ?: "");
    NSString *candidate = base;
    for (int i = 2; [NSFileManager.defaultManager fileExistsAtPath:[root stringByAppendingPathComponent:candidate]]; i++) {
        candidate = [NSString stringWithFormat:@"%@-%d", base, i];
    }
    return candidate;
}

- (void)create {
    if (self.creating || !self.gameVersion) return;
    [self.nameField resignFirstResponder];
    if (![self loaderSupportsVersion]) {
        [self showError:[NSString stringWithFormat:@"%@ isn't available for Minecraft %@ yet. Pick another version or use Vanilla.",
                         AMELoaderTitle(self.loader), self.gameVersion]];
        return;
    }
    self.creating = YES;
    self.status = @"Creating…";
    [self.tableView reloadData];

    NSString *name = [self uniqueProfileName:[self.nameField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]];
    __weak typeof(self) weakSelf = self;
    void (^finish)(NSString *) = ^(NSString *versionId) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        NSMutableDictionary *profile = [NSMutableDictionary dictionary];
        profile[@"name"] = name;
        profile[@"lastVersionId"] = versionId;
        profile[@"type"] = @"custom";
        profile[@"created"] = NSDate.date.description;
        profile[@"gameDir"] = [self folderNameFor:name];   // own folder: mods, config, worlds, packs
        [PLProfiles.current saveProfile:profile withName:name];
        AMESelectInstance(name);
        [NSNotificationCenter.defaultCenter postNotificationName:@"ReloadProfileList" object:nil];

        if (self.loader == AMELoaderFabric && self.fabricAPISwitch.on) {
            self.status = @"Adding Fabric API…";
            [self.tableView reloadData];
            AMEInstanceInfo *info = [AMEInstanceInfo infoForProfileName:name];
            [AMEModrinth installProject:@"fabric-api" kind:AMEModrinthKindMod instance:info completion:^(NSArray *files, NSError *error) {
                // Fabric API failing to download shouldn't block the new instance.
                [self done:name];
            }];
        } else {
            [self done:name];
        }
    };

    if (self.loader == AMELoaderVanilla) {
        finish(self.gameVersion);
        return;
    }

    NSString *meta = self.loader == AMELoaderFabric ? @"https://meta.fabricmc.net/v2" : @"https://meta.quiltmc.org/v3";
    NSString *loadersURL = [NSString stringWithFormat:@"%@/versions/loader/%@", meta, self.gameVersion];
    [self getJSON:loadersURL completion:^(NSArray *loaders) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        NSString *loaderVersion = nil;
        if ([loaders isKindOfClass:NSArray.class]) {
            for (NSDictionary *entry in loaders) {
                NSDictionary *l = entry[@"loader"];
                if (!loaderVersion) loaderVersion = l[@"version"];
                if (l[@"stable"] == nil || [l[@"stable"] boolValue]) { loaderVersion = l[@"version"]; break; }
            }
        }
        if (!loaderVersion) {
            [self failCreate:[NSString stringWithFormat:@"Couldn't find %@ for Minecraft %@.", AMELoaderTitle(self.loader), self.gameVersion]];
            return;
        }
        NSString *profileURL = [NSString stringWithFormat:@"%@/versions/loader/%@/%@/profile/json", meta, self.gameVersion, loaderVersion];
        [self getJSON:profileURL completion:^(NSDictionary *json) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            NSString *versionId = [json isKindOfClass:NSDictionary.class] ? json[@"id"] : nil;
            if (versionId.length == 0) {
                [self failCreate:@"Couldn't download the loader. Check your connection and try again."];
                return;
            }
            NSString *jsonPath = [NSString stringWithFormat:@"%s/versions/%@/%@.json", getenv("POJAV_GAME_DIR"), versionId, versionId];
            [NSFileManager.defaultManager createDirectoryAtPath:jsonPath.stringByDeletingLastPathComponent
                                    withIntermediateDirectories:YES attributes:nil error:nil];
            NSError *error = saveJSONToFile(json, jsonPath);
            if (error) {
                [self failCreate:error.localizedDescription];
                return;
            }
            finish(versionId);
        }];
    }];
}

- (void)failCreate:(NSString *)message {
    self.creating = NO;
    self.status = nil;
    [self.tableView reloadData];
    [self showError:message];
}

- (void)done:(NSString *)name {
    self.creating = NO;
    self.status = nil;
    if (self.onCreated) {
        self.onCreated(name);
    } else {
        [self.navigationController popViewControllerAnimated:YES];
    }
}

- (void)showError:(NSString *)message {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Can't create instance" message:message
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return AMENewSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch ((AMENewSection)section) {
        case AMENewSectionName:    return 1;
        case AMENewSectionVersion: return 1;
        case AMENewSectionLoader:  return self.loader == AMELoaderFabric ? 4 : 3;
        case AMENewSectionCreate:  return 1;
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch ((AMENewSection)section) {
        case AMENewSectionName:    return @"Name";
        case AMENewSectionVersion: return @"Minecraft";
        case AMENewSectionLoader:  return @"Mod loader";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == AMENewSectionLoader) {
        if (![self loaderSupportsVersion]) {
            return [NSString stringWithFormat:@"%@ isn't available for %@ yet.", AMELoaderTitle(self.loader), self.gameVersion];
        }
        return @"Fabric runs most mods, including Sodium and Iris shaders. Vanilla can't use mods.";
    }
    if (section == AMENewSectionCreate) {
        return self.status ?: @"This instance gets its own mods, worlds and settings. The game downloads the first time you press Play.";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    switch ((AMENewSection)indexPath.section) {
        case AMENewSectionName: {
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            self.nameField.translatesAutoresizingMaskIntoConstraints = NO;
            [cell.contentView addSubview:self.nameField];
            UILayoutGuide *m = cell.contentView.layoutMarginsGuide;
            [NSLayoutConstraint activateConstraints:@[
                [self.nameField.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
                [self.nameField.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
                [self.nameField.topAnchor constraintEqualToAnchor:m.topAnchor],
                [self.nameField.bottomAnchor constraintEqualToAnchor:m.bottomAnchor],
                [self.nameField.heightAnchor constraintGreaterThanOrEqualToConstant:30],
            ]];
            break;
        }
        case AMENewSectionVersion:
            cell.textLabel.text = @"Version";
            cell.detailTextLabel.text = self.gameVersion ?: @"Loading…";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;
        case AMENewSectionLoader:
            if (indexPath.row < 3) {
                AMELoader l = (AMELoader)indexPath.row;
                cell.textLabel.text = AMELoaderTitle(l);
                cell.detailTextLabel.text = l == AMELoaderFabric ? @"Recommended" : nil;
                cell.accessoryType = (l == self.loader) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
            } else {
                cell.textLabel.text = @"Include Fabric API";
                cell.accessoryView = self.fabricAPISwitch;
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
            }
            break;
        case AMENewSectionCreate: {
            UIButton *create = [AMEDesign buttonWithTitle:self.creating ? @"Creating…" : @"Create Instance"
                                                   symbol:@"plus" style:AMEButtonStylePrimary];
            create.enabled = !self.creating && self.gameVersion != nil;
            [create addTarget:self action:@selector(create) forControlEvents:UIControlEventTouchUpInside];
            create.translatesAutoresizingMaskIntoConstraints = NO;
            cell.backgroundColor = UIColor.clearColor;
            cell.backgroundConfiguration = nil;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            [cell.contentView addSubview:create];
            [NSLayoutConstraint activateConstraints:@[
                [create.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:4],
                [create.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-4],
                [create.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor],
                [create.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor],
                [create.heightAnchor constraintGreaterThanOrEqualToConstant:56],
            ]];
            break;
        }
        default: break;
    }
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == AMENewSectionVersion) return self.versions.count > 0;
    if (indexPath.section == AMENewSectionLoader) return indexPath.row < 3;
    return NO;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.creating) return;
    if (indexPath.section == AMENewSectionVersion && self.versions.count) {
        AMEVersionPickerViewController *picker = [[AMEVersionPickerViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        picker.allVersions = self.versions;
        picker.selected = self.gameVersion;
        __weak typeof(self) weakSelf = self;
        picker.onPick = ^(NSString *version) {
            weakSelf.gameVersion = version;
            [weakSelf updateSuggestedName];
            [weakSelf.tableView reloadData];
        };
        [self.navigationController pushViewController:picker animated:YES];
    } else if (indexPath.section == AMENewSectionLoader && indexPath.row < 3) {
        self.loader = (AMELoader)indexPath.row;
        [self updateSuggestedName];
        [self.tableView reloadData];
    }
}

@end
