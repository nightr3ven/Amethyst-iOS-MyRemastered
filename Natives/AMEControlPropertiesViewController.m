//
//  AMEControlPropertiesViewController.m
//

#import "AMEControlPropertiesViewController.h"
#import "customcontrols/ControlDrawer.h"
#import "customcontrols/ControlJoystick.h"
#import "customcontrols/ControlSubButton.h"
#import "customcontrols/CustomControlsUtils.h"
#include "utils.h"

#pragma mark - Key names

typedef struct { int code; const char *name; } AMEKeyEntry;

// Grouped, friendly actions shown first in the picker.
static const AMEKeyEntry kTouchKeys[] = {
    {SPECIALBTN_MOUSEPRI, "Attack / break"}, {SPECIALBTN_MOUSESEC, "Use / place"},
    {SPECIALBTN_MOUSEMID, "Pick block"}, {SPECIALBTN_SCROLLUP, "Previous hotbar slot"},
    {SPECIALBTN_SCROLLDOWN, "Next hotbar slot"}, {SPECIALBTN_VIRTUALMOUSE, "Virtual mouse"},
};
static const AMEKeyEntry kGameKeys[] = {
    {32, "Jump"}, {340, "Sneak"}, {341, "Sprint"}, {69, "Inventory"}, {81, "Drop item"},
    {70, "Swap hands"}, {84, "Chat"}, {47, "Command (/)"}, {258, "Player list"}, {256, "Pause (Esc)"},
    {294, "Third person"}, {290, "Hide HUD"}, {291, "Screenshot"}, {292, "Debug screen (F3)"},
    {76, "Advancements"}, {49, "Hotbar 1"}, {50, "Hotbar 2"}, {51, "Hotbar 3"}, {52, "Hotbar 4"},
    {53, "Hotbar 5"}, {54, "Hotbar 6"}, {55, "Hotbar 7"}, {56, "Hotbar 8"}, {57, "Hotbar 9"},
};
static const AMEKeyEntry kAppKeys[] = {
    {SPECIALBTN_KEYBOARD, "Show keyboard"}, {SPECIALBTN_TOGGLECTRL, "Show / hide controls"},
    {SPECIALBTN_MENU, "Game menu"},
};

static NSString *AMEPrettyRawKeyName(NSString *raw) {
    raw = [raw stringByReplacingOccurrencesOfString:@"SPECIALBTN_" withString:@""];
    raw = [raw stringByReplacingOccurrencesOfString:@"DPAD_" withString:@"Arrow "];
    raw = [raw stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    if (raw.length <= 3) return raw;   // A, F5, 0
    return raw.lowercaseString.capitalizedString;
}

static void AMEAllRawKeys(NSArray<NSString *> **names, NSArray<NSNumber *> **codes) {
    static NSArray *sNames, *sCodes;
    if (!sNames) {
        NSMutableArray *n = [NSMutableArray array], *c = [NSMutableArray array];
        initKeycodeTable(n, c);
        sNames = n; sCodes = c;
    }
    *names = sNames; *codes = sCodes;
}

NSString *AMEControlKeyName(int keycode) {
    if (keycode == 0) return @"None";
    for (size_t i = 0; i < sizeof(kTouchKeys)/sizeof(*kTouchKeys); i++) if (kTouchKeys[i].code == keycode) return @(kTouchKeys[i].name);
    for (size_t i = 0; i < sizeof(kGameKeys)/sizeof(*kGameKeys); i++) if (kGameKeys[i].code == keycode) return @(kGameKeys[i].name);
    for (size_t i = 0; i < sizeof(kAppKeys)/sizeof(*kAppKeys); i++) if (kAppKeys[i].code == keycode) return @(kAppKeys[i].name);
    NSArray *names, *codes;
    AMEAllRawKeys(&names, &codes);
    NSUInteger idx = [codes indexOfObject:@(keycode)];
    return idx == NSNotFound ? [NSString stringWithFormat:@"Key %d", keycode] : AMEPrettyRawKeyName(names[idx]);
}

#pragma mark - Key picker

@interface AMEKeyPickerViewController : UITableViewController <UISearchResultsUpdating>
@property(nonatomic) int selected;
@property(nonatomic) BOOL allowNone;
@property(nonatomic, copy) void (^onPick)(int code);
@property(nonatomic) NSArray<NSDictionary *> *sections;   // {title, items:[{name, code}]}
@property(nonatomic) NSString *filter;
@end

@implementation AMEKeyPickerViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = @"Search actions and keys";
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    [self rebuild];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    self.filter = searchController.searchBar.text;
    [self rebuild];
}

static NSArray *AMEItems(const AMEKeyEntry *list, size_t n) {
    NSMutableArray *a = [NSMutableArray array];
    for (size_t i = 0; i < n; i++) [a addObject:@{@"name": @(list[i].name), @"code": @(list[i].code)}];
    return a;
}

- (void)rebuild {
    NSMutableArray *sections = [NSMutableArray array];
    if (self.allowNone) [sections addObject:@{@"title": @"", @"items": @[@{@"name": @"None", @"code": @0}]}];
    [sections addObject:@{@"title": @"Touch & mouse", @"items": AMEItems(kTouchKeys, sizeof(kTouchKeys)/sizeof(*kTouchKeys))}];
    [sections addObject:@{@"title": @"Minecraft", @"items": AMEItems(kGameKeys, sizeof(kGameKeys)/sizeof(*kGameKeys))}];
    [sections addObject:@{@"title": @"Launcher", @"items": AMEItems(kAppKeys, sizeof(kAppKeys)/sizeof(*kAppKeys))}];
    NSArray *names, *codes;
    AMEAllRawKeys(&names, &codes);
    NSMutableArray *raw = [NSMutableArray array];
    for (NSUInteger i = 0; i < names.count; i++) {
        int code = [codes[i] intValue];
        if (code <= 0) continue;   // specials and NONE are listed above
        [raw addObject:@{@"name": AMEPrettyRawKeyName(names[i]), @"code": codes[i]}];
    }
    [sections addObject:@{@"title": @"Keyboard keys", @"items": raw}];

    if (self.filter.length) {
        NSMutableArray *filtered = [NSMutableArray array];
        for (NSDictionary *sec in sections) {
            NSPredicate *p = [NSPredicate predicateWithFormat:@"name CONTAINS[cd] %@", self.filter];
            NSArray *items = [sec[@"items"] filteredArrayUsingPredicate:p];
            if (items.count) [filtered addObject:@{@"title": sec[@"title"], @"items": items}];
        }
        sections = filtered;
    }
    self.sections = sections;
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return self.sections.count; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return [self.sections[section][@"items"] count]; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSString *t = self.sections[section][@"title"];
    return t.length ? t : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"k"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"k"];
    NSDictionary *item = self.sections[indexPath.section][@"items"][indexPath.row];
    cell.textLabel.text = item[@"name"];
    cell.accessoryType = [item[@"code"] intValue] == self.selected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    int code = [self.sections[indexPath.section][@"items"][indexPath.row][@"code"] intValue];
    if (self.onPick) self.onPick(code);
    [self.navigationController popViewControllerAnimated:YES];
}

@end

#pragma mark - Properties list

typedef NS_ENUM(NSInteger, AMERow) {
    AMERowName, AMERowKey1, AMERowKey2, AMERowKey3, AMERowKey4,
    AMERowToggle, AMERowSwipe, AMERowPassThru, AMERowForwardLock, AMERowOpens,
    AMERowWidth, AMERowHeight, AMERowRound, AMERowOpacity, AMERowColor, AMERowBorder, AMERowBorderColor,
    AMERowShow,
};

@interface AMEControlPropertiesTable : UITableViewController <UITextFieldDelegate>
@property(nonatomic, weak) ControlButton *button;
@property(nonatomic) NSArray<NSDictionary *> *sections;   // {title, footer, rows:[@(AMERow)]}
@end

@implementation AMEControlPropertiesTable

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (BOOL)isJoystick { return [self.button isKindOfClass:ControlJoystick.class]; }
- (BOOL)isDrawer { return [self.button isKindOfClass:ControlDrawer.class]; }
- (BOOL)isLockedSub {
    return [self.button isKindOfClass:ControlSubButton.class] &&
        ![((ControlSubButton *)self.button).parentDrawer.drawerData[@"orientation"] isEqualToString:@"FREE"];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self rebuild];
}

- (void)rebuild {
    NSMutableArray *s = [NSMutableArray array];
    if (self.isJoystick) {
        [s addObject:@{@"title": @"Joystick", @"footer": @"Auto-run: push the stick all the way up to keep walking forward.", @"rows": @[@(AMERowForwardLock)]}];
    } else {
        NSMutableArray *rows = [NSMutableArray arrayWithObject:@(AMERowName)];
        if (self.isDrawer) {
            [rows addObject:@(AMERowOpens)];
        } else {
            [rows addObject:@(AMERowKey1)];
            [rows addObject:@(AMERowKey2)];
            NSArray *k = self.button.properties[@"keycodes"];
            if ([k[2] intValue] != 0 || [k[1] intValue] != 0) [rows addObject:@(AMERowKey3)];
            if ([k[3] intValue] != 0 || [k[2] intValue] != 0) [rows addObject:@(AMERowKey4)];
        }
        [s addObject:@{@"title": @"Button", @"footer": self.isDrawer ? @"A group shows its buttons when tapped. Add buttons to it from the toolbar." : @"“Also presses” sends more keys at the same time, for shortcuts like F3 + B.", @"rows": rows}];
        if (!self.isDrawer) {
            [s addObject:@{@"title": @"Behavior", @"footer": @"Stay pressed: tap once to hold, tap again to release. Slide between: keep your finger down and slide onto it. Move camera too: dragging from it also turns the camera.",
                           @"rows": @[@(AMERowToggle), @(AMERowSwipe), @(AMERowPassThru)]}];
        }
    }
    NSMutableArray *look = [NSMutableArray array];
    if (!self.isLockedSub) { [look addObject:@(AMERowWidth)]; [look addObject:@(AMERowHeight)]; }
    if (!self.isJoystick) [look addObject:@(AMERowRound)];
    [look addObjectsFromArray:@[@(AMERowOpacity), @(AMERowColor), @(AMERowBorder), @(AMERowBorderColor)]];
    [s addObject:@{@"title": @"Look", @"rows": look}];
    [s addObject:@{@"title": @"Show", @"footer": @"“In menus” means inventory, chests and other screens.", @"rows": @[@(AMERowShow)]}];
    self.sections = s;
    [self.tableView reloadData];
}

- (void)apply {
    @try { [self.button update]; } @catch (NSException *e) {}
    if (self.isDrawer) [(ControlDrawer *)self.button syncButtons];
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return self.sections.count; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return [self.sections[section][@"rows"] count]; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return self.sections[section][@"title"]; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section { return self.sections[section][@"footer"]; }

- (UISwitch *)switchFor:(NSString *)key {
    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = [self.button.properties[key] boolValue];
    __weak typeof(self) ws = self;
    [sw addAction:[UIAction actionWithHandler:^(UIAction *a) {
        ws.button.properties[key] = @(((UISwitch *)a.sender).isOn);
        [ws apply];
    }] forControlEvents:UIControlEventValueChanged];
    return sw;
}

- (UIView *)sliderFor:(NSString *)key min:(float)min max:(float)max scale:(float)scale label:(UILabel *)valueLabel suffix:(NSString *)suffix {
    UISlider *sl = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, 150, 30)];
    sl.minimumValue = min; sl.maximumValue = max;
    sl.value = [self.button.properties[key] floatValue] * scale;
    valueLabel.text = [NSString stringWithFormat:@"%d%@", (int)roundf(sl.value), suffix];
    __weak typeof(self) ws = self;
    [sl addAction:[UIAction actionWithHandler:^(UIAction *a) {
        UISlider *s = (UISlider *)a.sender;
        int v = (int)roundf(s.value);
        valueLabel.text = [NSString stringWithFormat:@"%d%@", v, suffix];
        ws.button.properties[key] = scale == 1 ? @(v) : @(v / scale);
        [ws apply];
    }] forControlEvents:UIControlEventValueChanged];
    return sl;
}

- (UIView *)stepperFor:(NSString *)key label:(UILabel *)valueLabel {
    UIStepper *st = [[UIStepper alloc] init];
    st.minimumValue = 20; st.maximumValue = 400; st.stepValue = 2;
    st.value = [self.button.properties[key] doubleValue];
    valueLabel.text = [NSString stringWithFormat:@"%d pt", (int)st.value];
    __weak typeof(self) ws = self;
    [st addAction:[UIAction actionWithHandler:^(UIAction *a) {
        UIStepper *s = (UIStepper *)a.sender;
        valueLabel.text = [NSString stringWithFormat:@"%d pt", (int)s.value];
        ws.button.properties[key] = @(s.value);
        [ws apply];
    }] forControlEvents:UIControlEventValueChanged];
    return st;
}

- (UIView *)colorWellFor:(NSString *)key {
    UIColorWell *well = [[UIColorWell alloc] initWithFrame:CGRectMake(0, 0, 32, 32)];
    well.supportsAlpha = YES;
    well.selectedColor = convertARGB2UIColor([self.button.properties[key] intValue]);
    __weak typeof(self) ws = self;
    [well addAction:[UIAction actionWithHandler:^(UIAction *a) {
        ws.button.properties[key] = @(convertUIColor2ARGB(((UIColorWell *)a.sender).selectedColor));
        [ws apply];
    }] forControlEvents:UIControlEventValueChanged];
    return well;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    AMERow row = [self.sections[indexPath.section][@"rows"][indexPath.row] integerValue];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    NSMutableDictionary *p = self.button.properties;
    NSArray *keys = p[@"keycodes"];
    switch (row) {
        case AMERowName: {
            cell.textLabel.text = @"Label";
            UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 170, 30)];
            tf.textAlignment = NSTextAlignmentRight;
            tf.text = [[p[@"name"] description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
            tf.placeholder = @"Text on the button";
            tf.returnKeyType = UIReturnKeyDone;
            tf.delegate = self;
            tf.clearButtonMode = UITextFieldViewModeWhileEditing;
            __weak typeof(self) ws = self;
            [tf addAction:[UIAction actionWithHandler:^(UIAction *a) {
                ws.button.properties[@"name"] = ((UITextField *)a.sender).text ?: @"";
                [ws apply];
            }] forControlEvents:UIControlEventEditingChanged];
            cell.accessoryView = tf;
        } break;
        case AMERowKey1: case AMERowKey2: case AMERowKey3: case AMERowKey4: {
            NSInteger i = row - AMERowKey1;
            cell.textLabel.text = i == 0 ? @"Action" : (i == 1 ? @"Also presses" : @"And");
            cell.detailTextLabel.text = AMEControlKeyName([keys[i] intValue]);
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        } break;
        case AMERowOpens: {
            cell.textLabel.text = @"Opens";
            NSArray *values = @[@"DOWN", @"UP", @"LEFT", @"RIGHT", @"FREE"];
            UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[@"Down", @"Up", @"Left", @"Right", @"Free"]];
            NSString *cur = ((ControlDrawer *)self.button).drawerData[@"orientation"];
            seg.selectedSegmentIndex = MAX(0, (NSInteger)[values indexOfObject:cur ?: @"DOWN"]);
            __weak typeof(self) ws = self;
            [seg addAction:[UIAction actionWithHandler:^(UIAction *a) {
                ((ControlDrawer *)ws.button).drawerData[@"orientation"] = values[((UISegmentedControl *)a.sender).selectedSegmentIndex];
                [ws apply];
            }] forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = seg;
            [seg sizeToFit];
        } break;
        case AMERowToggle: cell.textLabel.text = @"Stay pressed"; cell.accessoryView = [self switchFor:@"isToggle"]; break;
        case AMERowSwipe: cell.textLabel.text = @"Slide between buttons"; cell.accessoryView = [self switchFor:@"isSwipeable"]; break;
        case AMERowPassThru: cell.textLabel.text = @"Move camera too"; cell.accessoryView = [self switchFor:@"passThruEnabled"]; break;
        case AMERowForwardLock: cell.textLabel.text = @"Auto-run"; cell.accessoryView = [self switchFor:@"forwardLock"]; break;
        case AMERowWidth: case AMERowHeight: {
            NSString *key = row == AMERowWidth ? @"width" : @"height";
            cell.textLabel.text = row == AMERowWidth ? @"Width" : @"Height";
            UILabel *value = [[UILabel alloc] init];
            value.textColor = UIColor.secondaryLabelColor;
            value.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightRegular];
            UIView *stepper = [self stepperFor:key label:value];
            UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[value, stepper]];
            stack.spacing = 10; stack.alignment = UIStackViewAlignmentCenter;
            stack.frame = CGRectMake(0, 0, 170, 32);
            cell.accessoryView = stack;
        } break;
        case AMERowRound: case AMERowOpacity: case AMERowBorder: {
            UILabel *value = [[UILabel alloc] init];
            value.textColor = UIColor.secondaryLabelColor;
            value.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightRegular];
            [value.widthAnchor constraintEqualToConstant:44].active = YES;
            value.textAlignment = NSTextAlignmentRight;
            UIView *slider;
            if (row == AMERowRound) { cell.textLabel.text = @"Roundness"; slider = [self sliderFor:@"cornerRadius" min:0 max:100 scale:1 label:value suffix:@"%"]; }
            else if (row == AMERowOpacity) { cell.textLabel.text = @"Opacity"; slider = [self sliderFor:@"opacity" min:5 max:100 scale:100 label:value suffix:@"%"]; }
            else { cell.textLabel.text = @"Border"; slider = [self sliderFor:@"strokeWidth" min:0 max:8 scale:1 label:value suffix:@""]; }
            UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[slider, value]];
            stack.spacing = 8; stack.alignment = UIStackViewAlignmentCenter;
            stack.frame = CGRectMake(0, 0, 190, 32);
            cell.accessoryView = stack;
        } break;
        case AMERowColor: cell.textLabel.text = @"Color"; cell.accessoryView = [self colorWellFor:@"bgColor"]; break;
        case AMERowBorderColor: cell.textLabel.text = @"Border color"; cell.accessoryView = [self colorWellFor:@"strokeColor"]; break;
        case AMERowShow: {
            UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[@"Always", @"In game", @"In menus"]];
            BOOL g = [p[@"displayInGame"] boolValue], m = [p[@"displayInMenu"] boolValue];
            seg.selectedSegmentIndex = (g && m) ? 0 : (g ? 1 : (m ? 2 : UISegmentedControlNoSegment));
            __weak typeof(self) ws = self;
            [seg addAction:[UIAction actionWithHandler:^(UIAction *a) {
                NSInteger i = ((UISegmentedControl *)a.sender).selectedSegmentIndex;
                ws.button.properties[@"displayInGame"] = @(i != 2);
                ws.button.properties[@"displayInMenu"] = @(i != 1);
            }] forControlEvents:UIControlEventValueChanged];
            seg.translatesAutoresizingMaskIntoConstraints = NO;
            [cell.contentView addSubview:seg];
            [NSLayoutConstraint activateConstraints:@[
                [seg.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
                [seg.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
                [seg.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:8],
                [seg.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-8],
            ]];
        } break;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    AMERow row = [self.sections[indexPath.section][@"rows"][indexPath.row] integerValue];
    if (row < AMERowKey1 || row > AMERowKey4) return;
    NSInteger i = row - AMERowKey1;
    AMEKeyPickerViewController *picker = [[AMEKeyPickerViewController alloc] init];
    picker.title = i == 0 ? @"Action" : @"Also presses";
    picker.allowNone = i > 0;
    picker.selected = [self.button.properties[@"keycodes"][i] intValue];
    __weak typeof(self) ws = self;
    picker.onPick = ^(int code) {
        NSMutableArray *k = [ws.button.properties[@"keycodes"] mutableCopy];
        while (k.count < 4) [k addObject:@0];
        k[i] = @(code);
        ws.button.properties[@"keycodes"] = k;
        // Give an unnamed button the action's name, so "New" never sticks around.
        NSString *name = [ws.button.properties[@"name"] description];
        if (i == 0 && (name.length == 0 || [name isEqualToString:@"New"] || [name isEqualToString:@"Button"])) {
            ws.button.properties[@"name"] = AMEControlKeyName(code);
        }
        [ws apply];
        [ws rebuild];
    };
    [self.navigationController pushViewController:picker animated:YES];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

@end

#pragma mark - Panel container

@interface AMEControlPropertiesViewController ()
@property(nonatomic) ControlButton *button;
@property(nonatomic) NSMutableDictionary *oldProperties;
@property(nonatomic) NSString *oldOrientation;
@property(nonatomic) UINavigationController *nav;
@end

@implementation AMEControlPropertiesViewController

- (instancetype)initWithButton:(ControlButton *)button {
    if ((self = [super init])) {
        _button = button;
        // Deep copy so Cancel can restore nested arrays (keycodes) too.
        _oldProperties = [NSPropertyListSerialization propertyListWithData:
            [NSPropertyListSerialization dataWithPropertyList:button.properties format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil]
            options:NSPropertyListMutableContainersAndLeaves format:nil error:nil] ?: button.properties.mutableCopy;
        if ([button isKindOfClass:ControlDrawer.class]) _oldOrientation = ((ControlDrawer *)button).drawerData[@"orientation"];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    // Tap outside the panel = Done.
    UIControl *outside = [[UIControl alloc] initWithFrame:self.view.bounds];
    outside.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [outside addTarget:self action:@selector(done) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:outside];

    AMEControlPropertiesTable *table = [[AMEControlPropertiesTable alloc] init];
    table.button = self.button;
    NSString *name = [[self.button.properties[@"name"] description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    table.title = [self.button isKindOfClass:ControlJoystick.class] ? @"Joystick" : ([self.button isKindOfClass:ControlDrawer.class] ? @"Group" : (name.length ? name : @"Button"));
    table.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
    table.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
    self.nav = [[UINavigationController alloc] initWithRootViewController:table];
    self.nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [self addChildViewController:self.nav];
    self.nav.view.layer.cornerRadius = 20;
    self.nav.view.layer.cornerCurve = kCACornerCurveContinuous;
    self.nav.view.clipsToBounds = YES;
    self.nav.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.nav.view];
    [self.nav didMoveToParentViewController:self];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    NSLayoutConstraint *side = self.panelOnLeft
        ? [self.nav.view.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8]
        : [self.nav.view.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8];
    NSLayoutConstraint *width = [self.nav.view.widthAnchor constraintEqualToConstant:380];
    width.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        side, width,
        [self.nav.view.widthAnchor constraintLessThanOrEqualToAnchor:self.view.widthAnchor multiplier:0.9],
        [self.nav.view.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:8],
        [self.nav.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-8],
    ]];
}

- (void)cancel {
    [self.button.properties removeAllObjects];
    [self.button.properties addEntriesFromDictionary:self.oldProperties];
    if (self.oldOrientation) ((ControlDrawer *)self.button).drawerData[@"orientation"] = self.oldOrientation;
    @try { [self.button update]; } @catch (NSException *e) {}
    if ([self.button isKindOfClass:ControlDrawer.class]) [(ControlDrawer *)self.button syncButtons];
    [self finishWithChanges:[NSMutableDictionary dictionary]];
}

- (void)done {
    [self.view endEditing:YES];
    NSMutableDictionary *changed = [NSMutableDictionary dictionary];
    for (NSString *key in self.button.properties) {
        if (![self.oldProperties[key] isEqual:self.button.properties[key]]) changed[key] = self.button.properties[key];
    }
    [self finishWithChanges:changed];
}

- (void)finishWithChanges:(NSMutableDictionary *)changed {
    void (^cb)(NSMutableDictionary *, NSMutableDictionary *) = self.onFinish;
    NSMutableDictionary *old = self.oldProperties;
    [self dismissViewControllerAnimated:YES completion:^{
        if (cb) cb(old, changed);
    }];
}

@end
