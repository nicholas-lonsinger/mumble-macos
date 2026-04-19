#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Phase 0 scaffolding. Later sub-tasks wire this to Qt core objects
/// via Obj-C++; Qt headers never appear in this public interface.
@interface MUMBridgeHost : NSObject

@property (nonatomic, copy, readonly) NSString *greeting;

/// Invoked on the main queue after `greeting` changes. The bridge
/// guarantees main-queue dispatch so Swift observers can safely
/// write to `@MainActor`-isolated state.
@property (nonatomic, copy, nullable) void (^onGreetingChanged)(void);

/// Simulate a background-thread signal that mutates `greeting` and
/// hops back to the main queue before firing `onGreetingChanged`.
/// Proves the marshalling pattern in Phase 0 sub-task 5; later
/// phases replace this with real `QObject::connect` hookups.
- (void)simulateBackgroundGreetingUpdate;

@end

NS_ASSUME_NONNULL_END
