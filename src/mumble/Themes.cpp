// Copyright The Mumble Developers. All rights reserved.
// Use of this source code is governed by a BSD-style license
// that can be found in the LICENSE file at the root of the
// Mumble source tree or at <https://www.mumble.info/LICENSE>.

#include "Themes.h"
#include "MainWindow.h"
#include "MumbleApplication.h"
#include "Settings.h"
#include "Global.h"

#include <QProcess>
#include <QStyleHints>

#include <optional>

// declared in ThemeSwitch_macx.mm
extern void setLightAppearance();
extern void setDarkAppearance();
extern void resetAppearanceToSystem();

std::optional< ThemeInfo::StyleInfo > Themes::getThemeStyle(const Settings &settings, bool darkMode) {
	QString themeStyleName = darkMode ? settings.themeDarkStyleName : settings.themeStyleName;
	QString themeName      = darkMode ? settings.themeDarkName : settings.themeName;

	if (themeName.isEmpty() && themeStyleName.isEmpty()) {
		return std::nullopt;
	}

	const ThemeMap themes = getThemes();
	auto themeIt          = themes.find(themeName);
	if (themeIt == themes.end()) {
		qWarning() << "Could not find configured theme" << themeName;
		return std::nullopt;
	}

	auto styleIt = themeIt->styles.find(themeStyleName);
	if (styleIt == themeIt->styles.end()) {
		qWarning() << "Configured theme \"" << themeName << "\" does not have configured style \"" << themeStyleName
				   << "\"";
		return std::nullopt;
	}

	return *styleIt;
}

std::optional< ThemeInfo::StyleInfo > Themes::getConfiguredStyle(const Settings &settings) {
	switch (settings.styleType) {
		case StyleType::Light:
			return getThemeStyle(settings, false);
		case StyleType::Dark:
			return getThemeStyle(settings, true);
		case StyleType::Auto:
			return getThemeStyle(settings, detectSystemDarkTheme());
	}
	assert(false);
	return std::nullopt; // fallback (should not normally reach here)
}

bool Themes::setConfiguredStyleHelper(QString &themeName, QString &themeStyleName,
									  std::optional< ThemeInfo::StyleInfo > style) {
	if (style) {
		if (themeName != style->themeName || themeStyleName != style->name) {
			themeName      = style->themeName;
			themeStyleName = style->name;
			return true;
		}
	} else {
		if (!themeName.isEmpty() || !themeStyleName.isEmpty()) {
			themeName = themeStyleName = QString();
			return true;
		}
	}
	return false;
}

bool Themes::setConfiguredStyle(Settings &settings, std::optional< ThemeInfo::StyleInfo > style) {
	return setConfiguredStyleHelper(settings.themeName, settings.themeStyleName, style);
}

bool Themes::setConfiguredDarkStyle(Settings &settings, std::optional< ThemeInfo::StyleInfo > style) {
	return setConfiguredStyleHelper(settings.themeDarkName, settings.themeDarkStyleName, style);
}

void Themes::applyFallback() {
	qWarning() << "Applying fallback style sheet";

	QStringList skinPaths;
	skinPaths << QLatin1String(":/themes/Default");
	QString defaultTheme = getDefaultStylesheet();
	setTheme(defaultTheme, skinPaths);
}

bool Themes::applyConfigured() {
	std::optional< ThemeInfo::StyleInfo > style = Themes::getConfiguredStyle(Global::get().s);
	if (!style) {
		return false;
	}

	const QFileInfo qssFile(style->getPlatformQss());

	qWarning() << "Theme:" << style->themeName;
	qWarning() << "Style:" << style->name;
	qWarning() << "--> qss:" << qssFile.absoluteFilePath();

	switch (Global::get().s.styleType) {
		case StyleType::Light:
			setLightAppearance();
			break;
		case StyleType::Dark:
			setDarkAppearance();
			break;
		case StyleType::Auto:
			resetAppearanceToSystem();
			break;
	}

	QFile file(qssFile.absoluteFilePath());
	if (!file.open(QFile::ReadOnly)) {
		qWarning() << "Failed to open theme stylesheet:" << file.errorString();
		return false;
	}

	QStringList skinPaths;
	skinPaths << qssFile.path();
	skinPaths << QLatin1String(":/themes/Default"); // Some skins might want to fall-back on our built-in resources

	QString themeQss = QString::fromUtf8(file.readAll());
	setTheme(themeQss, skinPaths);
	return true;
}

void Themes::setTheme(QString &themeQss, QStringList &skinPaths) {
	QDir::setSearchPaths(QLatin1String("skin"), skinPaths);

	QString userStylesheetFn = userStylesheetPath();
	QString userStylesheetContent;
	if (readStylesheet(userStylesheetFn, userStylesheetContent)) {
		qWarning("Themes: allowing user stylesheet at '%s' to override the stylesheet", qPrintable(userStylesheetFn));
	}

	qApp->setStyleSheet(themeQss + QLatin1String("\n") + userStylesheetContent);
}

bool Themes::apply() {
	const bool result = applyConfigured();
	if (!result) {
		applyFallback();
	}

	if (Global::get().mw) {
		Global::get().mw->qteLog->document()->setDefaultStyleSheet(qApp->styleSheet());
	}
	return result;
}

bool Themes::detectSystemDarkTheme() {
	Qt::ColorScheme colorScheme = QGuiApplication::styleHints()->colorScheme();
	if (colorScheme != Qt::ColorScheme::Unknown) {
		return colorScheme == Qt::ColorScheme::Dark;
	}
	// Fall back to comparing palette lightness values when the platform reports Unknown.
	QPalette defaultPalette;
	return defaultPalette.color(QPalette::WindowText).lightness() > defaultPalette.color(QPalette::Window).lightness();
}

ThemeMap Themes::getThemes() {
	return ThemeInfo::scanDirectories(getSearchDirectories());
}

QDir Themes::getUserThemesDirectory() {
	return QDir(Global::get().qdBasePath.absolutePath() + QLatin1String("/Themes"));
}

QVector< QDir > Themes::getSearchDirectories() {
	QVector< QDir > themeSearchDirectories;

	// Built-in themes contained in the binary have the lowest priority
	themeSearchDirectories << QDir(QLatin1String(":themes"));
	// Next come themes found in the applications Themes directory
	themeSearchDirectories << QDir(MumbleApplication::instance()->applicationVersionRootPath()
								   + QLatin1String("/Themes"));
	// Highest priority have themes located in the user directory
	themeSearchDirectories << getUserThemesDirectory();

	return themeSearchDirectories;
}

QString Themes::userStylesheetPath() {
	return Global::get().qdBasePath.absolutePath() + QLatin1String("/user.qss");
}

bool Themes::readStylesheet(const QString &stylesheetFn, QString &stylesheetContent) {
	QFile file(stylesheetFn);
	if (!file.open(QFile::ReadOnly)) {
		stylesheetContent = QString();
		return false;
	}

	stylesheetContent = QString::fromUtf8(file.readAll());
	return true;
}

QString Themes::getDefaultStylesheet() {
	return QLatin1String(".log-channel{text-decoration:none;}.log-user{text-decoration:none;}p{margin:0;}#qwMacWarning,"
						 "#qwInlineNotice{background-color:#FFFEDC;border-radius:5px;border:1px solid #B5B59E;}"
						 "#qwMacWarning > QLabel,#qwInlineNotice > QLabel{color:#333;}");
}
