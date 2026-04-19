#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Phase 0 scaffolding. Later sub-tasks wire this to Qt core objects
/// via Obj-C++; Qt headers never appear in this public interface.
@interface MUMBridgeHost : NSObject

@property (nonatomic, copy, readonly) NSString *greeting;

@end

NS_ASSUME_NONNULL_END
