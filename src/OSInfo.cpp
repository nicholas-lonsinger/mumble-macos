// Copyright The Mumble Developers. All rights reserved.
// Use of this source code is governed by a BSD-style license
// that can be found in the LICENSE file at the root of the
// Mumble source tree or at <https://www.mumble.info/LICENSE>.

#include "OSInfo.h"

#include "Version.h"

#include <QtCore/QCryptographicHash>
#include <QtCore/QSysInfo>
#include <QtNetwork/QNetworkInterface>
#include <QtXml/QDomDocument>

#include <sys/sysctl.h>

QString OSInfo::getArchitecture(const bool build) {
	QString architecture = build ? QSysInfo::buildCpuArchitecture() : QSysInfo::currentCpuArchitecture();
	if (architecture == QLatin1String("x86_64")) {
		architecture = QLatin1String("x64");
	} else if (architecture == QLatin1String("i386")) {
		architecture = QLatin1String("x86");
	}

	return architecture;
}

QString OSInfo::getMacHash(const QList< QHostAddress > &qlBind) {
	QString first, second, third;
	for (const QNetworkInterface &qni : QNetworkInterface::allInterfaces()) {
		if (!qni.isValid())
			continue;
		if (qni.flags() & QNetworkInterface::IsLoopBack)
			continue;
		if (qni.hardwareAddress().isEmpty())
			continue;

		QString hash = QString::fromUtf8(
			QCryptographicHash::hash(qni.hardwareAddress().toUtf8(), QCryptographicHash::Sha1).toHex());

		if (third.isEmpty() || third > hash)
			third = hash;

		if (!(qni.flags() & (QNetworkInterface::IsUp | QNetworkInterface::IsRunning)))
			continue;

		if (second.isEmpty() || second > hash)
			second = hash;

		for (const QNetworkAddressEntry &qnae : qni.addressEntries()) {
			const QHostAddress &qha = qnae.ip();
			if (qlBind.isEmpty() || qlBind.contains(qha)) {
				if (first.isEmpty() || first > hash)
					first = hash;
			}
		}
	}
	if (!first.isEmpty())
		return first;
	if (!second.isEmpty())
		return second;
	if (!third.isEmpty())
		return third;
	return QString();
}

QString OSInfo::getOS() {
	return QLatin1String("macOS");
}

QString OSInfo::getOSDisplayableVersion(const bool appendArch) {
	const QString os = QLatin1String("macOS ") + getOSVersion();
	if (!appendArch) {
		return os;
	}

	return os + QString(" [%1]").arg(getArchitecture(false));
}

QString OSInfo::getOSVersion() {
	const QString version = QSysInfo::productVersion();

	char buildno_buf[32];
	size_t sz_buildno_buf = sizeof(buildno_buf);
	if (sysctlbyname("kern.osversion", buildno_buf, &sz_buildno_buf, nullptr, 0) == 0) {
		return version + QLatin1Char(' ') + QString::fromLatin1(buildno_buf);
	}
	return version;
}

void OSInfo::fillXml(QDomDocument &doc, QDomElement &root, const QList< QHostAddress > &qlBind) {
	QDomElement tag = doc.createElement(QLatin1String("machash"));
	root.appendChild(tag);
	QDomText t = doc.createTextNode(getMacHash(qlBind));
	tag.appendChild(t);

	tag = doc.createElement(QLatin1String("arch"));
	root.appendChild(tag);
	t = doc.createTextNode(getArchitecture(true));
	tag.appendChild(t);

	tag = doc.createElement(QLatin1String("version"));
	root.appendChild(tag);
	t = doc.createTextNode(Version::getRelease());
	tag.appendChild(t);

	tag = doc.createElement(QLatin1String("release"));
	root.appendChild(tag);
	t = doc.createTextNode(Version::getRelease());
	tag.appendChild(t);

	tag = doc.createElement(QLatin1String("os"));
	root.appendChild(tag);
	t = doc.createTextNode(getOS());
	tag.appendChild(t);

	tag = doc.createElement(QLatin1String("osarch"));
	root.appendChild(tag);
	t = doc.createTextNode(getArchitecture(false));
	tag.appendChild(t);

	tag = doc.createElement(QLatin1String("osver"));
	root.appendChild(tag);
	t = doc.createTextNode(getOSVersion());
	tag.appendChild(t);

	tag = doc.createElement(QLatin1String("osverbose"));
	root.appendChild(tag);
	t = doc.createTextNode(getOSDisplayableVersion(false));
	tag.appendChild(t);

	tag = doc.createElement(QLatin1String("qt"));
	root.appendChild(tag);
	t = doc.createTextNode(QString::fromLatin1(qVersion()));
	tag.appendChild(t);

	QString cpu_id, cpu_extid;
	bool bSSE2 = false;

	tag = doc.createElement(QLatin1String("cpu_id"));
	root.appendChild(tag);
	t = doc.createTextNode(cpu_id);
	tag.appendChild(t);

	tag = doc.createElement(QLatin1String("cpu_extid"));
	root.appendChild(tag);
	t = doc.createTextNode(cpu_extid);
	tag.appendChild(t);

	tag = doc.createElement(QLatin1String("cpu_sse2"));
	root.appendChild(tag);
	t = doc.createTextNode(QString::number(bSSE2 ? 1 : 0));
	tag.appendChild(t);
}
