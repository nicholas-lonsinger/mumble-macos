// Copyright The Mumble Developers. All rights reserved.
// Use of this source code is governed by a BSD-style license
// that can be found in the LICENSE file at the root of the
// Mumble source tree or at <https://www.mumble.info/LICENSE>.

#include "EnvUtils.h"

#include <QByteArray>

namespace EnvUtils {

QString getenv(QString name) {
	QByteArray name8bit = name.toLocal8Bit();
	char *val           = ::getenv(name8bit.constData());
	if (!val) {
		return QString();
	}
	return QString::fromLocal8Bit(val);
}

bool setenv(QString name, QString value) {
	const int OVERWRITE = 1;
	return ::setenv(name.toLocal8Bit().constData(), value.toLocal8Bit().constData(), OVERWRITE) == 0;
}

} // namespace EnvUtils
