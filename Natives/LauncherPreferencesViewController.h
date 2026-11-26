#import <UIKit/UIKit.h>
#import "PLPrefTableViewController.h"

@interface LauncherPreferencesViewController : PLPrefTableViewController <UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIColorPickerViewControllerDelegate>

/// Redesign: show only some settings, as a plain always-expanded list.
/// Each entry is @[sectionKey] (whole section) or @[sectionKey, @[itemKey, ...]]
/// (those items, in that order). Values are still stored as "section.key".
/// Per-section header titles for category pages (empty string = none).
@property(nonatomic) NSArray<NSString *> *ameHeaders;
@property(nonatomic, copy) NSArray<NSArray *> *ameCategory;

@end
