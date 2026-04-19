#import "MUMBridgeHost.h"

#include <QtCore/QObject>

@implementation MUMBridgeHost

- (instancetype)init {
	self = [super init];
	if (self) {
		// Prove the Obj-C++ bridge can see and link against Qt core
		// types. Real bridge wiring (connecting signals, observing
		// Qt properties) lands in Phase 0 sub-task 8.
		QObject *probe = new QObject();
		delete probe;

		_greeting = @"Hello from Obj-C++";
	}
	return self;
}

@end
