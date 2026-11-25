//
//  AMEHomeViewController.m
//

#import "AMEHomeViewController.h"
#import "AMEDesign.h"
#import "LauncherRightPanelViewController.h"
#import "ProfileSettingsViewController.h"
#import "PLProfiles.h"
#import "authenticator/BaseAuthenticator.h"

#pragma mark - Hero card

@interface AMEHomeHeroCell : UITableViewCell
@property(nonatomic, strong) UIView *statusDot;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UIButton *versionButton;
@property(nonatomic, strong) UIButton *accountButton;
@property(nonatomic, strong) UIButton *playButton;
@end

@implementation AMEHomeHeroCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    self.statusDot = [[UIView alloc] init];
    self.statusDot.layer.cornerRadius = 4;
    self.statusDot.backgroundColor = UIColor.systemGrayColor;
    self.statusDot.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [self.statusDot.widthAnchor constraintEqualToConstant:8],
        [self.statusDot.heightAnchor constraintEqualToConstant:8],
    ]];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    self.statusLabel.adjustsFontForContentSizeCategory = YES;
    self.statusLabel.numberOfLines = 2;

    UIStackView *statusRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.statusDot, self.statusLabel]];
    statusRow.spacing = 8;
    statusRow.alignment = UIStackViewAlignmentCenter;

    self.titleLabel = [[UILabel alloc] init];
    UIFont *title = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle1];
    self.titleLabel.font = [UIFont fontWithDescriptor:[title.fontDescriptor fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitBold] size:0];
    self.titleLabel.adjustsFontForContentSizeCategory = YES;
    self.titleLabel.numberOfLines = 2;
    self.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.titleLabel.minimumScaleFactor = 0.6;

    self.versionButton = [AMEDesign buttonWithTitle:@"Version" symbol:@"cube.box" style:AMEButtonStyleSecondary];
    self.accountButton = [AMEDesign buttonWithTitle:@"Account" symbol:@"person.crop.circle" style:AMEButtonStyleSecondary];
    self.versionButton.accessibilityHint = @"Choose which version to play";
    self.accountButton.accessibilityHint = @"Switch or add accounts";

    UIStackView *chips = [[UIStackView alloc] initWithArrangedSubviews:@[self.versionButton, self.accountButton]];
    chips.spacing = 10;
    chips.distribution = UIStackViewDistributionFillEqually;

    self.playButton = [AMEDesign buttonWithTitle:@"Play" symbol:@"play.fill" style:AMEButtonStylePrimary];
    [self.playButton.heightAnchor constraintGreaterThanOrEqualToConstant:56].active = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[statusRow, self.titleLabel, chips, self.playButton]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14;
    [stack setCustomSpacing:6 afterView:statusRow];
    [stack setCustomSpacing:20 afterView:chips];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:20],
        [stack.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-20],
        [stack.leadingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.leadingAnchor constant:4],
        [stack.trailingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.trailingAnchor constant:-4],
    ]];
    return self;
}

@end

#pragma mark - Rows

@interface AMEHomeRow : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy, nullable) NSString *subtitle;
@property(nonatomic, copy) NSString *symbol;
@property(nonatomic, strong) UIColor *color;
@property(nonatomic, copy) void (^action)(void);
@end
@implementation AMEHomeRow
@end

static AMEHomeRow *AMERow(NSString *title, NSString *subtitle, NSString *symbol, UIColor *color, void (^action)(void)) {
    AMEHomeRow *row = [[AMEHomeRow alloc] init];
    row.title = title;
    row.subtitle = subtitle;
    row.symbol = symbol;
    row.color = color;
    row.action = action;
    return row;
}

#pragma mark - Home

static NSString *const kHeroCell = @"hero";
static NSString *const kRowCell = @"row";

@interface AMEHomeViewController ()
@property(nonatomic, copy) NSDictionary *state;
@property(nonatomic, copy) NSArray<NSString *> *sectionTitles;
@property(nonatomic, copy) NSArray<NSArray<AMEHomeRow *> *> *sections;
@end

@implementation AMEHomeViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.tableView.cellLayoutMarginsFollowReadableWidth = YES;
    self.tableView.estimatedRowHeight = 60;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    [self.tableView registerClass:AMEHomeHeroCell.class forCellReuseIdentifier:kHeroCell];
    self.view.tintColor = AMEDesign.accentColor;

    UILabel *header = [[UILabel alloc] init];
    UIFont *large = [UIFont preferredFontForTextStyle:UIFontTextStyleLargeTitle];
    header.font = [UIFont fontWithDescriptor:[large.fontDescriptor fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitBold] size:0];
    header.text = @"Home";
    header.adjustsFontForContentSizeCategory = YES;
    UIView *headerWrap = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 64)];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [headerWrap addSubview:header];
    [NSLayoutConstraint activateConstraints:@[
        [header.leadingAnchor constraintEqualToAnchor:headerWrap.layoutMarginsGuide.leadingAnchor],
        [header.bottomAnchor constraintEqualToAnchor:headerWrap.bottomAnchor constant:-4],
    ]];
    headerWrap.preservesSuperviewLayoutMargins = YES;
    self.tableView.tableHeaderView = headerWrap;

    [self buildSections];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(stateChanged:)
                                               name:AmeRightPanelStateNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh)
                                               name:@"SelectedProfileChanged" object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh)
                                               name:@"UpdateAccountInfo" object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refresh];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)refresh {
    [NSNotificationCenter.defaultCenter postNotificationName:AmeRightPanelRequestStateNotification object:nil];
    [self.tableView reloadData];
}

- (void)stateChanged:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL hadDownloads = [self downloadsActive];
        self.state = note.userInfo;
        if (hadDownloads != [self downloadsActive]) {
            [self.tableView reloadData];
            return;
        }
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationNone];
    });
}

#pragma mark - Data

- (BOOL)downloadsActive {
    return [self.state[@"dcActive"] boolValue];
}

- (NSString *)selectedProfileName {
    return PLProfiles.current.selectedProfileName;
}

- (NSString *)currentVersionTitle {
    NSString *version = self.state[@"version"];
    if ([version isKindOfClass:NSString.class] && version.length > 0) return version;
    NSString *profile = [self selectedProfileName];
    NSString *last = profile ? PLProfiles.current.profiles[profile][@"lastVersionId"] : nil;
    return last.length > 0 ? last : @"No version selected";
}

- (NSString *)currentAccountTitle {
    NSString *user = self.state[@"user"];
    if ([user isKindOfClass:NSString.class] && user.length > 0) return user;
    BaseAuthenticator *auth = BaseAuthenticator.current;
    NSString *name = auth.authData[@"username"];
    return name.length > 0 ? name : @"Sign in";
}

- (void)buildSections {
    __weak typeof(self) weakSelf = self;
    void (^post)(NSString *) = ^(NSString *name) {
        [NSNotificationCenter.defaultCenter postNotificationName:name object:nil];
    };

    NSArray<AMEHomeRow *> *instance = @[
        AMERow(@"Mods", @"Turn mods on or off, or remove them", @"puzzlepiece.extension.fill", UIColor.systemOrangeColor, ^{ post(@"ShowModsManager"); }),
        AMERow(@"Shaders", @"Choose and manage shader packs", @"sparkles", UIColor.systemPurpleColor, ^{ post(@"ShowShadersManager"); }),
        AMERow(@"Version settings", @"Renderer, memory, Java and more", @"slider.horizontal.3", UIColor.systemGrayColor, ^{ [weakSelf openVersionSettings]; }),
        AMERow(@"Game folder", @"Saves, screenshots and config files", @"folder.fill", UIColor.systemBlueColor, ^{ post(@"ShowGameDirectory"); }),
    ];
    NSArray<AMEHomeRow *> *add = @[
        AMERow(@"Download", @"New versions, mods, shaders and packs", @"arrow.down.circle.fill", AMEDesign.accentColor, ^{ [weakSelf switchToTab:1]; }),
        AMERow(@"Import a modpack", @"From a .zip or .mrpack file", @"shippingbox.fill", UIColor.systemBrownColor, ^{ post(@"ShowModpackImport"); }),
        AMERow(@"Run a .jar installer", @"Forge, OptiFine and other installers", @"hammer.fill", UIColor.systemIndigoColor, ^{ [LauncherRightPanelViewController norightPostAction:@"executeJar"]; }),
    ];
    NSArray<AMEHomeRow *> *together = @[
        AMERow(@"Multiplayer", @"Play with friends over the internet", @"person.2.fill", UIColor.systemTealColor, ^{ post(@"ShowMultiplayer"); }),
    ];

    self.sectionTitles = @[@"", @"This version", @"Add content", @"Play together"];
    self.sections = @[@[], instance, add, together];
}

#pragma mark - Actions

- (void)play {
    [LauncherRightPanelViewController norightPostAction:@"launch"];
}

- (void)pickVersion {
    [LauncherRightPanelViewController norightPostAction:@"versionPicker"];
}

- (void)manageAccounts {
    [LauncherRightPanelViewController norightPostAction:@"accountManager"];
}

- (void)openDownloads {
    [LauncherRightPanelViewController norightPostAction:@"downloadCenter"];
}

- (void)switchToTab:(NSUInteger)index {
    UITabBarController *tabs = self.tabBarController ?: self.parentViewController.tabBarController;
    if (index < tabs.viewControllers.count) tabs.selectedIndex = index;
}

- (void)openVersionSettings {
    NSString *profile = [self selectedProfileName];
    if (profile.length == 0) {
        [self pickVersion];
        return;
    }
    ProfileSettingsViewController *vc = [[ProfileSettingsViewController alloc] init];
    vc.profileName = profile;
    [self pushOnHostNavigation:vc];
}

/// Home lives inside LauncherRootViewController, whose navigation bar is hidden
/// on the root page; show it while a pushed page is on screen (Root hides it
/// again when you come back).
- (void)pushOnHostNavigation:(UIViewController *)vc {
    UINavigationController *nav = self.navigationController ?: self.parentViewController.navigationController;
    if (!nav) {
        UINavigationController *modal = [[UINavigationController alloc] initWithRootViewController:vc];
        vc.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                             target:self action:@selector(dismissPresented)];
        [self presentViewController:modal animated:YES completion:nil];
        return;
    }
    [nav setNavigationBarHidden:NO animated:YES];
    [nav pushViewController:vc animated:YES];
}

- (void)dismissPresented {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return [self downloadsActive] ? 2 : 1;
    return self.sections[section].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSString *title = self.sectionTitles[section];
    return title.length ? title : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0 && indexPath.row == 0) {
        return [self heroCellForTableView:tableView indexPath:indexPath];
    }

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kRowCell]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kRowCell];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.detailTextLabel.numberOfLines = 2;

    if (indexPath.section == 0) {
        NSString *progress = self.state[@"dcProgress"];
        NSString *badge = self.state[@"dcBadge"];
        cell.textLabel.text = @"Downloads in progress";
        cell.detailTextLabel.text = progress.length ? progress : (badge.length ? [NSString stringWithFormat:@"%@ remaining", badge] : @"Tap to see progress");
        cell.imageView.image = [AMEDesign iconTileWithSymbol:@"arrow.down.circle.fill" color:UIColor.systemBlueColor];
        return cell;
    }

    AMEHomeRow *row = self.sections[indexPath.section][indexPath.row];
    cell.textLabel.text = row.title;
    cell.detailTextLabel.text = row.subtitle;
    cell.imageView.image = [AMEDesign iconTileWithSymbol:row.symbol color:row.color];
    return cell;
}

- (UITableViewCell *)heroCellForTableView:(UITableView *)tableView indexPath:(NSIndexPath *)indexPath {
    AMEHomeHeroCell *cell = [tableView dequeueReusableCellWithIdentifier:kHeroCell forIndexPath:indexPath];

    cell.titleLabel.text = [self currentVersionTitle];
    [AMEDesign setTitle:@"Change version" ofButton:cell.versionButton];
    [AMEDesign setTitle:[self currentAccountTitle] ofButton:cell.accountButton];

    NSString *jit = self.state[@"jit"];
    UIColor *jitColor = self.state[@"jitColor"];
    cell.statusLabel.text = jit.length ? jit : @"Checking JIT…";
    cell.statusDot.backgroundColor = [jitColor isKindOfClass:UIColor.class] ? jitColor : UIColor.systemGrayColor;

    NSString *launchTitle = self.state[@"launchTitle"];
    NSNumber *enabled = self.state[@"launchEnabled"];
    [AMEDesign setTitle:(launchTitle.length ? launchTitle : @"Play") ofButton:cell.playButton];
    cell.playButton.enabled = enabled ? enabled.boolValue : YES;

    [cell.playButton removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
    [cell.versionButton removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
    [cell.accountButton removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
    [cell.playButton addTarget:self action:@selector(play) forControlEvents:UIControlEventTouchUpInside];
    [cell.versionButton addTarget:self action:@selector(pickVersion) forControlEvents:UIControlEventTouchUpInside];
    [cell.accountButton addTarget:self action:@selector(manageAccounts) forControlEvents:UIControlEventTouchUpInside];
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    return !(indexPath.section == 0 && indexPath.row == 0);
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        if (indexPath.row == 1) [self openDownloads];
        return;
    }
    AMEHomeRow *row = self.sections[indexPath.section][indexPath.row];
    if (row.action) row.action();
}

@end
