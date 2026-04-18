// Copyright The Mumble Developers. All rights reserved.
// Use of this source code is governed by a BSD-style license
// that can be found in the LICENSE file at the root of the
// Mumble source tree or at <https://www.mumble.info/LICENSE>.

#include "Zeroconf.h"

Zeroconf::Zeroconf() : m_ok(false) {
	qRegisterMetaType< uint16_t >("uint16_t");
	qRegisterMetaType< BonjourRecord >("BonjourRecord");
	qRegisterMetaType< QList< BonjourRecord > >("QList<BonjourRecord>");
	resetHelperBrowser();
	resetHelperResolver();

	m_ok = true;
}

Zeroconf::~Zeroconf() {
	if (!m_helperBrowser) {
		stopBrowser();
	}

	if (!m_helperResolver) {
		cleanupResolvers();
	}
}

void Zeroconf::resetHelperBrowser() {
	m_helperBrowser.reset(new BonjourServiceBrowser(this));
	connect(m_helperBrowser.get(), &BonjourServiceBrowser::currentBonjourRecordsChanged, this,
			&Zeroconf::helperBrowserRecordsChanged);
	connect(m_helperBrowser.get(), &BonjourServiceBrowser::error, this, &Zeroconf::helperBrowserError);
}

void Zeroconf::resetHelperResolver() {
	m_helperResolver.reset(new BonjourServiceResolver(this));
	connect(m_helperResolver.get(), &BonjourServiceResolver::bonjourRecordResolved, this,
			&Zeroconf::helperResolverRecordResolved);
	connect(m_helperResolver.get(), &BonjourServiceResolver::error, this, &Zeroconf::helperResolverError);
}

bool Zeroconf::startBrowser(const QString &serviceType) {
	if (!m_ok) {
		return false;
	}

	stopBrowser();

	if (m_helperBrowser) {
		m_helperBrowser->browseForServiceType(serviceType);
		return true;
	}
	return false;
}

bool Zeroconf::stopBrowser() {
	if (!m_ok) {
		return false;
	}

	if (m_helperBrowser) {
		resetHelperBrowser();
		return true;
	}
	return true;
}

bool Zeroconf::startResolver(const BonjourRecord &record) {
	if (!m_ok) {
		return false;
	}

	if (m_helperResolver) {
		m_helperResolver->resolveBonjourRecord(record);
		return true;
	}
	return false;
}
bool Zeroconf::cleanupResolvers() {
	if (!m_ok) {
		return false;
	}

	if (m_helperResolver) {
		resetHelperResolver();
		return true;
	}

	auto result = true;
	return result;
}

void Zeroconf::helperBrowserRecordsChanged(const QList< BonjourRecord > &records) {
	emit recordsChanged(records);
}

void Zeroconf::helperResolverRecordResolved(const BonjourRecord record, const QString hostname, const int port) {
	emit recordResolved(record, hostname, static_cast< std::uint16_t >(port));
}

void Zeroconf::helperBrowserError(const DNSServiceErrorType error) const {
	qWarning("Zeroconf: Third-party browser API reports error %d", error);
}

void Zeroconf::helperResolverError(const BonjourRecord record, const DNSServiceErrorType error) {
	qWarning("Zeroconf: Third-party resolver API reports error %d", error);
	emit resolveError(record);
}
