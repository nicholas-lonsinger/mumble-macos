#import "MUMBridgeHost.h"

#include <QtCore/QObject>
#include <QtCore/QString>

@implementation MUMBridgeHost {
	QObject *_qtObject;
}

- (instancetype)init {
	self = [super init];
	if (self) {
		_qtObject = new QObject();

		__weak MUMBridgeHost *weakSelf = self;
		QObject::connect(_qtObject, &QObject::objectNameChanged,
			[weakSelf](const QString &name) {
				// Runs on whatever thread setObjectName was called
				// from. We only mutate objectName from the main
				// queue (see simulateBackgroundGreetingUpdate), so
				// this is main-thread by construction.
				MUMBridgeHost *strongSelf = weakSelf;
				if (!strongSelf) {
					return;
				}
				strongSelf->_greeting = name.toNSString();
				if (strongSelf.onGreetingChanged) {
					strongSelf.onGreetingChanged();
				}
			});

		// Seeding the name fires objectNameChanged, which populates
		// _greeting through the lambda above.
		_qtObject->setObjectName(QStringLiteral("Hello from a Qt-backed objectName"));
	}
	return self;
}

- (void)dealloc {
	delete _qtObject;
}

- (void)simulateBackgroundGreetingUpdate {
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSString *timestamp = [NSDate date].description;
		NSString *next = [NSString stringWithFormat:@"Qt signal at %@", timestamp];

		dispatch_async(dispatch_get_main_queue(), ^{
			// The block retains `next`, so the NSString is still
			// alive here. QString::fromNSString copies the contents,
			// side-stepping the autorelease-pool lifetime trap that
			// [NSString UTF8String] has across dispatch hops.
			self->_qtObject->setObjectName(QString::fromNSString(next));
		});
	});
}

@end
