//
//  AMEDownloadViewController.m
//

#import "AMEDownloadViewController.h"
#import "AMEDesign.h"
#import "AMEModrinth.h"
#import "AMEModBrowserViewController.h"
#import "AMENewInstanceViewController.h"
#import "AMEInstancesViewController.h"
#import "AmeRootTabController.h"
#import "DownloadViewController.h"
#import "ModpackImportViewController.h"
#import "PLProfiles.h"

@implementation AMEDownloadViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Download";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    self.view.tintColor = AMEDesign.accentColor;
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.tableView.cellLayoutMarginsFollowReadableWidth = YES;
    [NSNotificationCenter.defaultCenter addObserver:self.tableView selector:@selector(reloadData)
                                               name:@"SelectedProfileChanged" object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    [self.tableView reloadData];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self.tableView];
}

- (NSString *)selectedProfile {
    return PLProfiles.current.selectedProfileName;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 3 : section == 1 ? 2 : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) {
        NSString *p = [self selectedProfile];
        return p.length ? [NSString stringWithFormat:@"Modrinth · for %@", p] : @"Modrinth";
    }
    return section == 1 ? @"Instances" : @"More";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"Results only show things that work with this instance's Minecraft version and mod loader. Switch instances from the Instances tab.";
    if (section == 2) return @"Forge, NeoForge, OptiFine, CurseForge and every version type.";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    NSArray *row;
    if (indexPath.section == 0) {
        row = @[@[@"Mods", @"Sodium, Iris, Fabric API and thousands more", @"puzzlepiece.extension.fill", UIColor.systemOrangeColor],
                @[@"Shaders", @"Shader packs for Iris or OptiFine", @"sparkles", UIColor.systemPurpleColor],
                @[@"Resource packs", @"Textures, sounds and fonts", @"paintpalette.fill", UIColor.systemPinkColor]][indexPath.row];
    } else if (indexPath.section == 1) {
        row = @[@[@"New instance", @"Vanilla, Fabric or Quilt, any version", @"plus.square.fill", AMEDesign.accentColor],
                @[@"Import a modpack", @".mrpack or .zip from Modrinth or CurseForge", @"shippingbox.fill", UIColor.systemBrownColor]][indexPath.row];
    } else {
        row = @[@"Forge & NeoForge", @"Pick a game version, then a loader", @"hammer.fill", UIColor.systemGrayColor];
    }
    cell.textLabel.text = row[0];
    cell.detailTextLabel.text = row[1];
    cell.imageView.image = [AMEDesign iconTileWithSymbol:row[2] color:row[3]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    UIViewController *vc = nil;
    if (indexPath.section == 0) {
        NSString *profile = [self selectedProfile];
        if (profile.length == 0) {
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"No instance yet"
                                                                       message:@"Create an instance first."
                                                                preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:a animated:YES completion:nil];
            return;
        }
        vc = [[AMEModBrowserViewController alloc] initWithProfileName:profile kind:(AMEModrinthKind)indexPath.row];
    } else if (indexPath.section == 1 && indexPath.row == 0) {
        AMENewInstanceViewController *n = [[AMENewInstanceViewController alloc] init];
        __weak typeof(self) weakSelf = self;
        n.onCreated = ^(NSString *name) {
            [weakSelf.navigationController popToViewController:weakSelf animated:NO];
            AMEInstanceViewController *page = [[AMEInstanceViewController alloc] initWithProfileName:name];
            [weakSelf.navigationController pushViewController:page animated:YES];
        };
        vc = n;
    } else if (indexPath.section == 1) {
        vc = [[ModpackImportViewController alloc] init];
    } else {
        DownloadViewController *d = [[DownloadViewController alloc] init];
        d.versionsOnly = YES;
        vc = d;
    }
    vc.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    [self.navigationController pushViewController:vc animated:YES];
}

@end
