// Copyright The Mumble Developers. All rights reserved.
// Use of this source code is governed by a BSD-style license
// that can be found in the LICENSE file at the root of the
// Mumble source tree or at <https://www.mumble.info/LICENSE>.

#include "VersionCheck.h"

#include "MainWindow.h"
#include "Utils.h"
#include "WebFetch.h"
#include "Global.h"

#include <QtCore/QUrlQuery>
#include <QtWidgets/QMessageBox>
#include <QtXml/QDomDocument>

#include <QtConcurrent/QtConcurrent>

VersionCheck::VersionCheck(bool autocheck, QObject *p, bool focus) : QObject(p), m_preparationWatcher() {
	connect(&m_preparationWatcher, &QFutureWatcher< void >::finished, this, &VersionCheck::performRequest);

	QFuture< void > future = QtConcurrent::run([this, autocheck, focus]() {
		m_requestURL.setPath(focus ? QLatin1String("/v1/banner") : QLatin1String("/v1/version-check"));

		QList< QPair< QString, QString > > queryItems;
		queryItems << qMakePair(QString::fromLatin1("ver"),
								QString::fromLatin1(QUrl::toPercentEncoding(Version::getRelease())));
#if defined(USE_MAC_UNIVERSAL)
		queryItems << qMakePair(QString::fromLatin1("os"), QString::fromLatin1("MacOSX-Universal"));
#else
		queryItems << qMakePair(QString::fromLatin1("os"), QString::fromLatin1("MacOSX"));
#endif
		if (!Global::get().s.bUsage)
			queryItems << qMakePair(QString::fromLatin1("nousage"), QString::fromLatin1("1"));
		if (autocheck)
			queryItems << qMakePair(QString::fromLatin1("auto"), QString::fromLatin1("1"));

		queryItems << qMakePair(QString::fromLatin1("locale"), Global::get().s.qsLanguage.isEmpty()
																   ? QLocale::system().name()
																   : Global::get().s.qsLanguage);

		QFile f(qApp->applicationFilePath());
		if (!f.open(QIODevice::ReadOnly)) {
			qWarning("VersionCheck: Failed to open binary");
		} else {
			QByteArray a = f.readAll();
			if (a.size() < 1) {
				qWarning("VersionCheck: suspiciously small binary");
			} else {
				QCryptographicHash qch(QCryptographicHash::Sha1);
				qch.addData(a);
				queryItems << qMakePair(QString::fromLatin1("sha1"), QString::fromLatin1(qch.result().toHex()));
			}
		}

		QUrlQuery query;
		query.setQueryItems(queryItems);
		m_requestURL.setQuery(query);
	});

	m_preparationWatcher.setFuture(future);
}

void VersionCheck::performRequest() {
	WebFetch::fetch(QLatin1String("update"), m_requestURL, this, SLOT(fetched(QByteArray, QUrl)));
}

void VersionCheck::fetched(QByteArray a, QUrl url) {
	if (!a.isNull()) {
		if (!a.isEmpty()) {
#ifdef SNAPSHOT_BUILD
			if (url.path() == QLatin1String("/v1/banner")) {
				Global::get().mw->msgBox(QString::fromUtf8(a));
			} else if (url.path() == QLatin1String("/v1/version-check")) {
				Global::get().mw->msgBox(QString::fromUtf8(a));
			}
#else
			Q_UNUSED(url);
			Global::get().mw->msgBox(QString::fromUtf8(a));
#endif
		}
	} else {
		Global::get().mw->msgBox(tr("Mumble failed to retrieve version information from the central server."));
	}

	deleteLater();
}
