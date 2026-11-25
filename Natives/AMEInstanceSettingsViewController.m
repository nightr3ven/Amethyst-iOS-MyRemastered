//
//  AMEInstanceSettingsViewController.m
//

#import "AMEInstanceSettingsViewController.h"
#import "AMEDesign.h"
#import "AMEModrinth.h"
#import "PLProfiles.h"
#import "LauncherPreferences.h"
#import "utils.h"

#pragma mark - Option picker

@interface AMEOptionPickerViewController ()
@property(nonatomic, copy) NSArray<NSString *> *values, *titles;
@property(nonatomic, copy, nullable) NSArray<NSString *> *subtitles;
@property(nonatomic, copy, nullable) NSString *selected, *footer;
@property(nonatomic, copy) void (^onPick)(NSString *);
@end

@implementation AMEOptionPickerViewController

- (instancetype)initWithTitle:(NSString *)title values:(NSArray<NSString *> *)values titles:(NSArray<NSString *> *)titles
                    subtitles:(NSArray<NSString *> *)subtitles selected:(NSString *)selected footer:(NSString *)footer
                       onPick:(void (^)(NSString *))onPick {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.title = title;
        _values = values; _titles = titles; _subtitles = subtitles;
        _selected = selected; _footer = footer; _onPick = onPick;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.tintColor = AMEDesign.accentColor;
    self.tableView.cellLayoutMarginsFollowReadableWidth = YES;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.values.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return self.footer;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text = self.titles[indexPath.row];
    if (indexPath.row < (NSInteger)self.subtitles.count && self.subtitles[indexPath.row].length) {
        cell.detailTextLabel.text = self.subtitles[indexPath.row];
        cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        cell.detailTextLabel.numberOfLines = 0;
    }
    cell.accessoryType = [self.values[indexPath.row] isEqualToString:self.selected]
        ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    self.selected = self.values[indexPath.row];
    [tableView reloadData];
    self.onPick(self.selected);
    [self.navigationController popViewControllerAnimated:YES];
}

@end

#pragma mark - Instance settings

typedef NS_ENUM(NSInteger, AMESettingsRow) {
    AMERowName, AMERowVersion,
    AMERowRenderer, AMERowGraphicsAPI,
    AMERowJava, AMERowJVMArgs, AMERowServer,
};

@interface AMEInstanceSettingsViewController ()
@property(nonatomic, copy) NSString *profileName;
@property(nonatomic, copy) NSArray<NSArray<NSNumber *> *> *sections;
@property(nonatomic, copy) NSArray<NSString *> *sectionTitles;
@end

@implementation AMEInstanceSettingsViewController

- (instancetype)initWithProfileName:(NSString *)profileName {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) _profileName = [profileName copy];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Instance Settings";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.view.tintColor = AMEDesign.accentColor;
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.tableView.cellLayoutMarginsFollowReadableWidth = YES;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self rebuild];
}

- (NSMutableDictionary *)profile {
    return PLProfiles.current.profiles[self.profileName];
}

- (BOOL)isModernVersion {
    AMEInstanceInfo *info = [AMEInstanceInfo infoForProfileName:self.profileName];
    NSString *v = info.gameVersion ?: info.versionId;
    NSInteger major = [[v componentsSeparatedByString:@"."].firstObject integerValue];
    return major >= 26;
}

- (void)rebuild {
    NSMutableArray *performance = [NSMutableArray arrayWithObject:@(AMERowRenderer)];
    if ([self isModernVersion]) [performance addObject:@(AMERowGraphicsAPI)];
    self.sections = @[
        @[@(AMERowName), @(AMERowVersion)],
        performance,
        @[@(AMERowJava), @(AMERowJVMArgs), @(AMERowServer)],
    ];
    self.sectionTitles = @[@"General", @"Graphics", @"Advanced"];
    [self.tableView reloadData];
}

- (void)save {
    [PLProfiles.current save];
    [NSNotificationCenter.defaultCenter postNotificationName:@"SelectedProfileChanged" object:nil];
    [self.tableView reloadData];
}

#pragma mark Values

- (NSArray *)rendererChoices {
    NSArray<NSString *> *keys = getRendererKeys(NO);
    NSMutableArray *values = [NSMutableArray array], *titles = [NSMutableArray array], *subtitles = [NSMutableArray array];
    for (NSString *key in keys) {
        NSString *k = key.lowercaseString;
        NSString *title = key, *sub = @"";
        if ([k isEqualToString:@"auto"]) { title = @"Automatic"; sub = @"Recommended. Picks what works for this Minecraft version."; }
        else if ([k containsString:@"mobileglues"]) { title = @"MobileGlues"; sub = @"Best for Minecraft 1.17 and newer, including 26.x and shaders."; }
        else if ([k containsString:@"angle"]) { title = @"ANGLE"; sub = @"Stable for older versions. Doesn't work with 26.x."; }
        else if ([k containsString:@"gl4es"]) { title = @"GL4ES"; sub = @"For very old versions (1.16 and below)."; }
        else if ([k containsString:@"osmesa"] || [k containsString:@"zink"]) { title = @"Zink"; sub = @"OpenGL on Vulkan. Experimental."; }
        else if ([k containsString:@"ltw"]) { title = @"LTW"; sub = @"Experimental."; }
        else if ([k containsString:@"vulkan"] || [k containsString:@"moltenvk"]) { title = @"Vulkan (MoltenVK)"; sub = @"Experimental."; }
        [values addObject:key]; [titles addObject:title]; [subtitles addObject:sub];
    }
    return @[values, titles, subtitles];
}

- (NSString *)rendererTitle {
    NSString *current = self.profile[@"renderer"] ?: @"auto";
    NSArray *c = [self rendererChoices];
    NSUInteger i = [c[0] indexOfObject:current];
    return i == NSNotFound ? current : c[1][i];
}

- (NSString *)graphicsTitle {
    NSString *g = self.profile[@"graphicsApi"];
    if ([g isEqualToString:@"prefer_vulkan"]) return @"Vulkan";
    if ([g isEqualToString:@"prefer_opengl"]) return @"OpenGL";
    return @"Automatic";
}

- (NSString *)javaValue {
    id raw = self.profile[@"javaVersion"];
    if ([raw isKindOfClass:NSDictionary.class]) raw = [raw[@"majorVersion"] description];
    NSString *v = [raw isKindOfClass:NSString.class] ? raw : @"0";
    return v.integerValue > 0 ? v : @"0";
}

- (NSString *)javaTitle {
    NSString *v = [self javaValue];
    return [v isEqualToString:@"0"] ? @"Automatic" : [@"Java " stringByAppendingString:v];
}

- (NSString *)serverValue {
    return [PLProfiles.current serverIpForProfile:self.profileName] ?: @"";
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.sections[section].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.sectionTitles[section];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"To play a different Minecraft version, create a new instance.";
    if (section == 1) return @"Leave these on Automatic unless something looks wrong.";
    if (section == 2) return @"Memory is set for all instances in Settings › Memory & Java.";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    AMESettingsRow row = (AMESettingsRow)self.sections[indexPath.section][indexPath.row].integerValue;
    switch (row) {
        case AMERowName:
            cell.textLabel.text = @"Name";
            cell.detailTextLabel.text = self.profileName;
            break;
        case AMERowVersion:
            cell.textLabel.text = @"Version";
            cell.detailTextLabel.text = self.profile[@"lastVersionId"];
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
        case AMERowRenderer:
            cell.textLabel.text = @"Renderer";
            cell.detailTextLabel.text = [self rendererTitle];
            break;
        case AMERowGraphicsAPI:
            cell.textLabel.text = @"Graphics API";
            cell.detailTextLabel.text = [self graphicsTitle];
            break;
        case AMERowJava:
            cell.textLabel.text = @"Java version";
            cell.detailTextLabel.text = [self javaTitle];
            break;
        case AMERowJVMArgs: {
            NSString *args = self.profile[@"javaArgs"];
            cell.textLabel.text = @"JVM arguments";
            cell.detailTextLabel.text = [args isKindOfClass:NSString.class] && args.length ? args : @"Default";
            break;
        }
        case AMERowServer: {
            NSString *server = [self serverValue];
            cell.textLabel.text = @"Join server on launch";
            cell.detailTextLabel.text = server.length ? server : @"Off";
            break;
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    AMESettingsRow row = (AMESettingsRow)self.sections[indexPath.section][indexPath.row].integerValue;
    __weak typeof(self) weakSelf = self;
    switch (row) {
        case AMERowName: {
            [self promptWithTitle:@"Rename instance" value:self.profileName placeholder:@"Name" done:^(NSString *text) {
                [weakSelf renameTo:text];
            }];
            break;
        }
        case AMERowVersion: {
            break;
        }
        case AMERowRenderer: {
            NSArray *c = [self rendererChoices];
            [self pushPicker:@"Renderer" values:c[0] titles:c[1] subtitles:c[2] selected:self.profile[@"renderer"] ?: @"auto" footer:nil set:^(NSString *v) {
                weakSelf.profile[@"renderer"] = v;
            }];
            break;
        }
        case AMERowGraphicsAPI: {
            [self pushPicker:@"Graphics API" values:@[@"default", @"prefer_opengl", @"prefer_vulkan"]
                      titles:@[@"Automatic", @"OpenGL", @"Vulkan"]
                   subtitles:@[@"Recommended.", @"Works with the MobileGlues renderer.", @"Experimental on iPhone; some effects may not compile."]
                    selected:self.profile[@"graphicsApi"] ?: @"default" footer:@"Minecraft 26.x can render with OpenGL or Vulkan."
                         set:^(NSString *v) { weakSelf.profile[@"graphicsApi"] = v; }];
            break;
        }
        case AMERowJava: {
            [self pushPicker:@"Java version" values:@[@"0", @"8", @"17", @"21", @"25"]
                      titles:@[@"Automatic", @"Java 8", @"Java 17", @"Java 21", @"Java 25"]
                   subtitles:@[@"Recommended. Matches the Minecraft version.", @"1.16 and older", @"1.17 – 1.20.4", @"1.20.5 – 1.21.x", @"26.x"]
                    selected:[self javaValue] footer:nil
                         set:^(NSString *v) { weakSelf.profile[@"javaVersion"] = v; }];
            break;
        }
        case AMERowJVMArgs: {
            NSString *args = self.profile[@"javaArgs"];
            [self promptWithTitle:@"JVM arguments" value:[args isKindOfClass:NSString.class] ? args : @"" placeholder:@"Leave empty for default" done:^(NSString *text) {
                if (text.length) weakSelf.profile[@"javaArgs"] = text;
                else [weakSelf.profile removeObjectForKey:@"javaArgs"];
                [weakSelf save];
            }];
            break;
        }
        case AMERowServer: {
            [self promptWithTitle:@"Join server on launch" value:[self serverValue] placeholder:@"play.example.com (empty = off)" done:^(NSString *text) {
                [PLProfiles.current setServerIp:text forProfile:weakSelf.profileName];
                weakSelf.profile[@"serverIp"] = text ?: @"";
                [weakSelf save];
            }];
            break;
        }
    }
}

- (void)pushPicker:(NSString *)title values:(NSArray *)values titles:(NSArray *)titles subtitles:(NSArray *)subtitles
          selected:(NSString *)selected footer:(NSString *)footer set:(void (^)(NSString *))set {
    __weak typeof(self) weakSelf = self;
    AMEOptionPickerViewController *picker = [[AMEOptionPickerViewController alloc] initWithTitle:title values:values titles:titles
                                                                                       subtitles:subtitles selected:selected footer:footer
                                                                                          onPick:^(NSString *value) {
        set(value);
        [weakSelf save];
    }];
    [self.navigationController pushViewController:picker animated:YES];
}

- (void)promptWithTitle:(NSString *)title value:(NSString *)value placeholder:(NSString *)placeholder done:(void (^)(NSString *))done {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:nil preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = value;
        field.placeholder = placeholder;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        done([a.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"");
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)renameTo:(NSString *)newName {
    if (newName.length == 0 || [newName isEqualToString:self.profileName]) return;
    if (PLProfiles.current.profiles[newName]) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Name already used"
                                                                   message:@"Pick a different name."
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    NSMutableDictionary *profile = self.profile;
    if (!profile) return;
    BOOL wasSelected = [PLProfiles.current.selectedProfileName isEqualToString:self.profileName];
    NSString *server = [self serverValue];
    profile[@"name"] = newName;
    PLProfiles.current.profiles[newName] = profile;
    [PLProfiles.current.profiles removeObjectForKey:self.profileName];
    if (server.length) [PLProfiles.current setServerIp:server forProfile:newName];
    if (wasSelected) PLProfiles.current.selectedProfileName = newName;
    self.profileName = newName;
    [PLProfiles.current save];
    [NSNotificationCenter.defaultCenter postNotificationName:@"ReloadProfileList" object:nil];
    [NSNotificationCenter.defaultCenter postNotificationName:@"SelectedProfileChanged" object:nil];
    // The instance page underneath is keyed by name; send the user back to the list.
    [self.navigationController popToRootViewControllerAnimated:YES];
}

@end
