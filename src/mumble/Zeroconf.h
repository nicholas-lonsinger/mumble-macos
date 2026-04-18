// Copyright The Mumble Developers. All rights reserved.
// Use of this source code is governed by a BSD-style license
// that can be found in the LICENSE file at the root of the
// Mumble source tree or at <https://www.mumble.info/LICENSE>.

#ifndef MUMBLE_MUMBLE_ZEROCONF_H_
#define MUMBLE_MUMBLE_ZEROCONF_H_

#include "BonjourServiceBrowser.h"
#include "BonjourServiceResolver.h"

#include <memory>

class Zeroconf : public QObject {
private:
	Q_OBJECT
	Q_DISABLE_COPY(Zeroconf)
protected:
	bool m_ok;
	QList< BonjourRecord > m_records;
	std::unique_ptr< BonjourServiceBrowser > m_helperBrowser;
	std::unique_ptr< BonjourServiceResolver > m_helperResolver;
	void resetHelperBrowser();
	void resetHelperResolver();

	void helperBrowserRecordsChanged(const QList< BonjourRecord > &records);
	void helperResolverRecordResolved(const BonjourRecord record, const QString hostname, const int port);
	void helperBrowserError(const DNSServiceErrorType error) const;
	void helperResolverError(const BonjourRecord record, const DNSServiceErrorType error);
public:
	inline bool isOk() const { return m_ok; }
	inline QList< BonjourRecord > currentRecords() const {
		return m_helperBrowser ? m_helperBrowser->currentRecords() : m_records;
	}

	bool startBrowser(const QString &serviceType);
	bool stopBrowser();

	bool startResolver(const BonjourRecord &record);
	bool cleanupResolvers();

	Zeroconf();
	~Zeroconf();
signals:
	void recordsChanged(const QList< BonjourRecord > &records);
	void recordResolved(const BonjourRecord record, const QString hostname, const uint16_t port);
	void resolveError(const BonjourRecord record);
};

#endif
