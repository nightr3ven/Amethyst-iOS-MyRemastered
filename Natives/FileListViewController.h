#import <UIKit/UIKit.h>

@interface FileListViewController : UITableViewController

@property NSString* listPath;
/// Name (without .json) of the item in use: shown with a checkmark and can't be deleted.
@property(nonatomic, copy) NSString *currentName;
@property (nonatomic, copy) void (^whenDelete)(NSString* name);
@property(nonatomic, copy) void (^whenItemSelected)(NSString* name);

@end
