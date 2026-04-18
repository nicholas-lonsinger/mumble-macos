// Copyright The Mumble Developers. All rights reserved.
// Use of this source code is governed by a BSD-style license
// that can be found in the LICENSE file at the root of the
// Mumble source tree or at <https://www.mumble.info/LICENSE>.

#ifndef MUMBLE_MUMBLE_ENVUTILS_H_
#define MUMBLE_MUMBLE_ENVUTILS_H_

#include <QString>

namespace EnvUtils {

// Wrapper around getenv that returns a QString (locale-encoded).
QString getenv(QString name);

bool setenv(QString name, QString value);

} // namespace EnvUtils

#endif
