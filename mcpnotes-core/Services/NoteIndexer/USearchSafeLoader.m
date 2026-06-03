#import "USearchSafeLoader.h"
#import "USearchObjective.h"

BOOL USearchSafeLoad(USearchIndex *index, NSString *path, NSError **error) {
    @try {
        [index load:path];
        return YES;
    }
    @catch (NSException *exception) {
        if (error) {
            NSString *reason = exception.reason ?: exception.name;
            *error = [NSError errorWithDomain:@"USearch"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: reason}];
        }
        return NO;
    }
}
