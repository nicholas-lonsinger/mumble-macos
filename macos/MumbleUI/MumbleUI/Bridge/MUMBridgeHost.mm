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
		_qtObject->setObjectName(QStringLiteral("Hello from a Qt-backed objectName"));

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
				strongSelf->_greeting = [NSString stringWithUTF8String:name.toUtf8().constData()];
				if (strongSelf.onGreetingChanged) {
					strongSelf.onGreetingChanged();
				}
			});

		_greeting = [NSString stringWithUTF8String:_qtObject->objectName().toUtf8().constData()];
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
		const char *nextUTF8 = [next UTF8String];

		dispatch_async(dispatch_get_main_queue(), ^{
			// Mutating the Qt object on main emits objectNameChanged
			// synchronously; our lambda above updates _greeting and
			// fires onGreetingChanged from inside the emission.
			self->_qtObject->setObjectName(QString::fromUtf8(nextUTF8));
		});
	});
}

@end
