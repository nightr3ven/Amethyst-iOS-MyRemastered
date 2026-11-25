//
//  AMEModBrowserViewController.m
//

#import "AMEModBrowserViewController.h"
#import "AMEDesign.h"
#import <SafariServices/SafariServices.h>

typedef NS_ENUM(NSInteger, AMEInstallState) {
    AMEInstallStateNone,
    AMEInstallStateInstalling,
    AMEInstallStateInstalled,
};

@interface AMEModResultCell : UITableViewCell
@property(nonatomic, strong) UIImageView *icon;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *metaLabel;
@property(nonatomic, strong) UILabel *summaryLabel;
@property(nonatomic, strong) UIButton *getButton;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@property(nonatomic, copy, nullable) NSURL *iconURL;
- (void)setInstallState:(AMEInstallState)state;
@end

@implementation AMEModResultCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;

    self.icon = [[UIImageView alloc] init];
    self.icon.layer.cornerRadius = 10;
    self.icon.layer.cornerCurve = kCACornerCurveContinuous;
    self.icon.clipsToBounds = YES;
    self.icon.backgroundColor = UIColor.tertiarySystemFillColor;
    self.icon.contentMode = UIViewContentModeScaleAspectFill;
    self.icon.translatesAutoresizingMaskIntoConstraints = NO;

    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    self.metaLabel = [[UILabel alloc] init];
    self.metaLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    self.metaLabel.textColor = UIColor.secondaryLabelColor;
    self.summaryLabel = [[UILabel alloc] init];
    self.summaryLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.summaryLabel.textColor = UIColor.secondaryLabelColor;
    self.summaryLabel.numberOfLines = 2;
    for (UILabel *l in @[self.titleLabel, self.metaLabel, self.summaryLabel]) l.adjustsFontForContentSizeCategory = YES;

    UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[self.titleLabel, self.metaLabel, self.summaryLabel]];
    text.axis = UILayoutConstraintAxisVertical;
    text.spacing = 2;
    text.translatesAutoresizingMaskIntoConstraints = NO;

    self.getButton = [AMEDesign buttonWithTitle:@"Get" symbol:nil style:AMEButtonStyleSecondary];
    self.getButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.getButton setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.getButton setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped = YES;
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;

    [self.contentView addSubview:self.icon];
    [self.contentView addSubview:text];
    [self.contentView addSubview:self.getButton];
    [self.contentView addSubview:self.spinner];

    UILayoutGuide *m = self.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.icon.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
        [self.icon.topAnchor constraintEqualToAnchor:text.topAnchor constant:2],
        [self.icon.widthAnchor constraintEqualToConstant:48],
        [self.icon.heightAnchor constraintEqualToConstant:48],
        [text.leadingAnchor constraintEqualToAnchor:self.icon.trailingAnchor constant:12],
        [text.topAnchor constraintEqualToAnchor:m.topAnchor],
        [text.bottomAnchor constraintEqualToAnchor:m.bottomAnchor],
        [self.icon.bottomAnchor constraintLessThanOrEqualToAnchor:m.bottomAnchor],
        [self.getButton.leadingAnchor constraintEqualToAnchor:text.trailingAnchor constant:12],
        [self.getButton.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
        [self.getButton.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [self.getButton.widthAnchor constraintGreaterThanOrEqualToConstant:76],
        [self.spinner.centerXAnchor constraintEqualToAnchor:self.getButton.centerXAnchor],
        [self.spinner.centerYAnchor constraintEqualToAnchor:self.getButton.centerYAnchor],
    ]];
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.icon.image = nil;
    self.iconURL = nil;
}

- (void)setInstallState:(AMEInstallState)state {
    switch (state) {
        case AMEInstallStateNone:
            self.getButton.hidden = NO;
            self.getButton.enabled = YES;
            [AMEDesign setTitle:@"Get" ofButton:self.getButton];
            [self.spinner stopAnimating];
            break;
        case AMEInstallStateInstalling:
            self.getButton.hidden = YES;
            [self.spinner startAnimating];
            break;
        case AMEInstallStateInstalled:
            self.getButton.hidden = NO;
            self.getButton.enabled = NO;
            [AMEDesign setTitle:@"Installed" ofButton:self.getButton];
            [self.spinner stopAnimating];
            break;
    }
}

@end

#pragma mark -

@interface AMEModBrowserViewController () <UISearchResultsUpdating, UISearchBarDelegate>
@property(nonatomic, copy) NSString *profileName;
@property(nonatomic) AMEModrinthKind kind;
@property(nonatomic, strong) AMEInstanceInfo *instance;
@property(nonatomic, strong) UISearchController *search;
@property(nonatomic, strong) UISegmentedControl *kindPicker;
@property(nonatomic, strong) NSMutableArray<AMEModrinthProject *> *results;
@property(nonatomic) NSInteger totalHits;
@property(nonatomic) BOOL loading;
@property(nonatomic, copy) NSString *query;
@property(nonatomic) NSUInteger requestToken;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *states;  // projectId -> AMEInstallState
@property(nonatomic, copy, nullable) NSString *errorText;
@end

@implementation AMEModBrowserViewController

- (instancetype)initWithProfileName:(NSString *)profileName kind:(AMEModrinthKind)kind {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _profileName = [profileName copy];
        _kind = kind;
        _results = [NSMutableArray array];
        _states = [NSMutableDictionary dictionary];
        _query = @"";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.instance = [AMEInstanceInfo infoForProfileName:self.profileName];
    self.view.tintColor = AMEDesign.accentColor;
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.tableView.cellLayoutMarginsFollowReadableWidth = YES;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    [self.tableView registerClass:AMEModResultCell.class forCellReuseIdentifier:@"result"];

    self.kindPicker = [[UISegmentedControl alloc] initWithItems:@[@"Mods", @"Shaders", @"Packs"]];
    self.kindPicker.selectedSegmentIndex = self.kind;
    [self.kindPicker addTarget:self action:@selector(kindChanged) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = self.kindPicker;

    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.searchResultsUpdater = self;
    self.search.obscuresBackgroundDuringPresentation = NO;
    self.search.searchBar.delegate = self;
    self.search.searchBar.placeholder = @"Search Modrinth";
    self.navigationItem.searchController = self.search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;

    UIRefreshControl *refresh = [[UIRefreshControl alloc] init];
    [refresh addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = refresh;

    [self reload];
}

- (void)kindChanged {
    self.kind = self.kindPicker.selectedSegmentIndex;
    [self reload];
}

- (NSString *)instanceDescription {
    if (!self.instance) return @"No instance selected";
    NSString *loader = self.instance.loader ? self.instance.loader.capitalizedString : @"Vanilla";
    if (self.kind != AMEModrinthKindMod) loader = nil;
    NSString *version = self.instance.gameVersion ?: @"any version";
    return loader ? [NSString stringWithFormat:@"%@ · %@ %@", self.profileName, loader, version]
                  : [NSString stringWithFormat:@"%@ · Minecraft %@", self.profileName, version];
}

#pragma mark Loading

- (void)reload {
    [self.results removeAllObjects];
    self.totalHits = 0;
    self.errorText = nil;
    [self.tableView reloadData];
    [self loadMore];
}

- (void)loadMore {
    if (!self.instance) {
        self.errorText = @"Select an instance first.";
        [self.refreshControl endRefreshing];
        [self.tableView reloadData];
        return;
    }
    if (self.kind == AMEModrinthKindMod && self.instance.loader == nil) {
        self.errorText = @"This instance is vanilla, so it can't run mods. Create a Fabric instance from the Instances tab to use mods.";
        [self.refreshControl endRefreshing];
        [self.tableView reloadData];
        return;
    }
    self.loading = YES;
    NSUInteger token = ++self.requestToken;
    NSInteger offset = self.results.count;
    __weak typeof(self) weakSelf = self;
    [AMEModrinth searchQuery:self.query kind:self.kind instance:self.instance offset:offset
                  completion:^(NSArray<AMEModrinthProject *> *results, NSInteger total, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || token != self.requestToken) return;
        self.loading = NO;
        [self.refreshControl endRefreshing];
        if (error) {
            self.errorText = error.localizedDescription;
        } else {
            [self.results addObjectsFromArray:results];
            self.totalHits = total;
            if (self.results.count == 0) self.errorText = @"Nothing found for this version.";
        }
        [self.tableView reloadData];
    }];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *q = [searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] ?: @"";
    if ([q isEqualToString:self.query]) return;
    self.query = q;
    // Small debounce so typing doesn't fire a request per letter.
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(reload) object:nil];
    [self performSelector:@selector(reload) withObject:nil afterDelay:0.35];
}

#pragma mark Install

- (AMEInstallState)stateForProject:(AMEModrinthProject *)p {
    NSNumber *s = self.states[p.projectId];
    if (s) return s.integerValue;
    return [AMEModrinth isProjectInstalled:p.projectId kind:self.kind instance:self.instance]
        ? AMEInstallStateInstalled : AMEInstallStateNone;
}

- (void)install:(UIButton *)sender {
    CGPoint point = [sender convertPoint:CGPointZero toView:self.tableView];
    NSIndexPath *path = [self.tableView indexPathForRowAtPoint:point];
    if (!path || path.row >= (NSInteger)self.results.count) return;
    AMEModrinthProject *project = self.results[path.row];
    AMEModrinthKind kind = self.kind;
    self.states[project.projectId] = @(AMEInstallStateInstalling);
    [self.tableView reloadRowsAtIndexPaths:@[path] withRowAnimation:UITableViewRowAnimationNone];

    __weak typeof(self) weakSelf = self;
    [AMEModrinth installProject:project.projectId kind:kind instance:self.instance completion:^(NSArray<NSString *> *files, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self.states[project.projectId] = @(error ? AMEInstallStateNone : AMEInstallStateInstalled);
        [self.tableView reloadData];
        if (error) {
            UIAlertController *a = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Couldn't install %@", project.title]
                                                                       message:error.localizedDescription
                                                                preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:a animated:YES completion:nil];
        } else if (files.count > 1) {
            [self flashMessage:[NSString stringWithFormat:@"Installed %@ and %lu required %@",
                                project.title, (unsigned long)files.count - 1, files.count == 2 ? @"mod" : @"mods"]];
        }
    }];
}

- (void)flashMessage:(NSString *)message {
    UILabel *label = [[UILabel alloc] init];
    label.text = message;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    label.textColor = UIColor.labelColor;
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 2;
    label.backgroundColor = UIColor.secondarySystemBackgroundColor;
    label.layer.cornerRadius = 14;
    label.layer.masksToBounds = YES;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.alpha = 0;
    [self.view.window addSubview:label];
    UILayoutGuide *safe = self.view.window.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [label.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [label.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-70],
        [label.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor constant:-48],
        [label.heightAnchor constraintGreaterThanOrEqualToConstant:44],
    ]];
    [UIView animateWithDuration:0.2 animations:^{ label.alpha = 1; } completion:^(BOOL f) {
        [UIView animateWithDuration:0.3 delay:2.2 options:0 animations:^{ label.alpha = 0; } completion:^(BOOL f2) {
            [label removeFromSuperview];
        }];
    }];
}

#pragma mark Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.results.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return [self instanceDescription];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (self.errorText) return self.errorText;
    if (self.loading) return @"Loading…";
    if (self.results.count && self.kind == AMEModrinthKindMod) return @"Required mods are installed automatically.";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    AMEModResultCell *cell = [tableView dequeueReusableCellWithIdentifier:@"result" forIndexPath:indexPath];
    AMEModrinthProject *p = self.results[indexPath.row];
    cell.titleLabel.text = p.title;
    NSString *downloads = p.downloads >= 1000000 ? [NSString stringWithFormat:@"%.1fM", p.downloads / 1e6]
                        : p.downloads >= 1000    ? [NSString stringWithFormat:@"%.0fK", p.downloads / 1e3]
                        : [NSString stringWithFormat:@"%ld", (long)p.downloads];
    cell.metaLabel.text = [NSString stringWithFormat:@"by %@ · %@ downloads", p.author, downloads];
    cell.summaryLabel.text = p.summary;
    [cell setInstallState:[self stateForProject:p]];
    [cell.getButton removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
    [cell.getButton addTarget:self action:@selector(install:) forControlEvents:UIControlEventTouchUpInside];

    cell.iconURL = p.iconURL;
    if (p.iconURL) {
        NSURL *url = p.iconURL;
        __weak AMEModResultCell *weakCell = cell;
        [AMEModrinth loadIcon:url completion:^(NSData *data) {
            if (data && [weakCell.iconURL isEqual:url]) weakCell.icon.image = [UIImage imageWithData:data];
        }];
    }

    if (indexPath.row == (NSInteger)self.results.count - 5 && !self.loading && (NSInteger)self.results.count < self.totalHits) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self loadMore]; });
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    AMEModrinthProject *p = self.results[indexPath.row];
    NSString *type = self.kind == AMEModrinthKindMod ? @"mod" : self.kind == AMEModrinthKindShader ? @"shader" : @"resourcepack";
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://modrinth.com/%@/%@", type, p.slug]];
    if (url) [self presentViewController:[[SFSafariViewController alloc] initWithURL:url] animated:YES completion:nil];
}

@end
