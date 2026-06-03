#import <Foundation/Foundation.h>
@class USearchIndex;

/// Calls [index load:path] inside @try/@catch.
/// Returns YES on success, NO on failure with *error set.
BOOL USearchSafeLoad(USearchIndex *index, NSString *path, NSError **error);
