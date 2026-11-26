//
//  AMESettingsViewController.m
//

#import "AMESettingsViewController.h"
#import "AMEDesign.h"
#import "LauncherPreferencesViewController.h"
#import "AccountListViewController.h"
#import "AI/AISessionListViewController.h"
#import "authenticator/BaseAuthenticator.h"

@interface AMESettingsItem : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy, nullable) NSString *subtitle;
@property(nonatomic, copy) NSString *symbol;
@property(nonatomic, strong) UIColor *color;
@property(nonatomic, copy, nullable) NSArray<NSArray *> *category;     // settings page
@property(nonatomic, copy, nullable) UIViewController *(^makeViewController)(void); // custom page
@end
@implementation AMESettingsItem
@end

static AMESettingsItem *AMEPage(NSString *title, NSString *subtitle, NSString *symbol, UIColor *color, NSArray<NSArray *> *category) {
    AMESettingsItem *item = [[AMESettingsItem alloc] init];
    item.title = title;
    item.subtitle = subtitle;
    item.symbol = symbol;
    item.color = color;
    item.category = category;
    return item;
}

static AMESettingsItem *AMECustom(NSString *title, NSString *subtitle, NSString *symbol, UIColor *color, UIViewController *(^make)(void)) {
    AMESettingsItem *item = AMEPage(title, subtitle, symbol, color, nil);
    item.makeViewController = make;
    return item;
}

@interface AMESettingsViewController ()
@property(nonatomic, copy) NSArray<NSArray<AMESettingsItem *> *> *sections;
@end

@implementation AMESettingsViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Settings";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    self.view.tintColor = AMEDesign.accentColor;
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.tableView.cellLayoutMarginsFollowReadableWidth = YES;

    AMESettingsItem *accounts = AMECustom(@"Accounts", nil, @"person.crop.circle.fill", UIColor.systemBlueColor, ^UIViewController *{
        AccountListViewController *vc = [[AccountListViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        vc.whenItemSelected = ^{
            [NSNotificationCenter.defaultCenter postNotificationName:@"UpdateAccountInfo" object:nil];
        };
        vc.whenDelete = ^(NSString *name) {
            [NSNotificationCenter.defaultCenter postNotificationName:@"UpdateAccountInfo" object:nil];
        };
        return vc;
    });

    self.sections = @[
        @[accounts],
        @[
            AMEPage(@"Graphics", @"Renderer, resolution, frame rate", @"display", UIColor.systemPurpleColor, @[
                @[@"video", @[@"renderer", @"resolution", @"performance_hud", @"disable_game_vsync", @"fullscreen_airplay"]],
            ]),
            AMEPage(@"Controls", @"Touch, mouse, gamepad, keyboard", @"gamecontroller.fill", UIColor.systemGreenColor, @[
                @[@"control"],
                @[@"debug", @[@"debug_auto_correction", @"debug_hide_home_indicator"]],
            ]),
            AMEPage(@"Sound", nil, @"speaker.wave.2.fill", UIColor.systemPinkColor, @[
                @[@"video", @[@"silence_other_audio", @"silence_with_switch", @"allow_microphone"]],
            ]),
            AMEPage(@"Memory & Java", @"How much RAM the game gets", @"memorychip.fill", UIColor.systemOrangeColor, @[
                @[@"java", @[@"auto_ram", @"allocated_memory", @"manage_runtime", @"java_args", @"env_variables"]],
            ]),
            AMEPage(@"Downloads", @"Where mods and versions come from", @"arrow.down.circle.fill", UIColor.systemTealColor, @[
                @[@"download"],
                @[@"general", @[@"curseforge_api_key", @"mod_mirror"]],
            ]),
            AMEPage(@"Appearance", @"Theme and background", @"paintbrush.fill", UIColor.systemIndigoColor, @[
                @[@"general", @[@"ui_theme", @"launcher_background"]],
            ]),
        ],
        @[
            AMEPage(@"AI Assistant", @"Chat that can find mods and read crash logs", @"sparkles", UIColor.systemYellowColor, @[
                @[@"ai"],
            ]),
            AMEPage(@"Advanced", @"JIT, renderer internals, debugging, reset", @"wrench.and.screwdriver.fill", UIColor.systemGrayColor, @[
                @[@"debug", @[@"jit_enabler", @"debug_universal_script_jit", @"debug_always_attached_jit", @"debug_skip_wait_jit", @"jit26_script_disable"]],
                @[@"mobileglues"],
                @[@"video", @[@"sfpew_overlay"]],
                @[@"java", @[@"dyld_bypass"]],
                @[@"general", @[@"multi_threaded", @"cosmetica", @"debug_logging", @"reset_warnings", @"reset_settings"]],
            ]),
        ],
    ];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.sections[section].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section != (NSInteger)self.sections.count - 1) return nil;
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    return [NSString stringWithFormat:@"Air %@ (%@) · redesign build",
            info[@"CFBundleShortVersionString"] ?: @"?", info[@"CFBundleVersion"] ?: @"?"];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"item"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"item"];
    AMESettingsItem *item = self.sections[indexPath.section][indexPath.row];
    cell.textLabel.text = item.title;
    cell.detailTextLabel.text = item.subtitle;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    cell.imageView.image = [AMEDesign iconTileWithSymbol:item.symbol color:item.color];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    if (item.makeViewController && [item.title isEqualToString:@"Accounts"]) {
        NSString *user = [BaseAuthenticator.current authData][@"username"];
        cell.detailTextLabel.text = user.length ? user : @"Not signed in";
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    AMESettingsItem *item = self.sections[indexPath.section][indexPath.row];
    UIViewController *vc = nil;
    if (item.makeViewController) {
        vc = item.makeViewController();
    } else {
        LauncherPreferencesViewController *page = [[LauncherPreferencesViewController alloc] init];
        page.ameCategory = item.category;
        vc = page;
    }
    vc.title = item.title;
    vc.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    [self.navigationController pushViewController:vc animated:YES];
}

@end
