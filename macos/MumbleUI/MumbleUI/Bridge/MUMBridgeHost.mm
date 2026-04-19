#import "MUMBridgeHost.h"

@implementation MUMBridgeHost

- (instancetype)init {
	self = [super init];
	if (self) {
		_greeting = @"Hello from Obj-C++";
	}
	return self;
}

@end
