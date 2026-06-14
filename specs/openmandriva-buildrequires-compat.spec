Name:           openmandriva-buildrequires-compat
Version:        1
Release:        1%{?dist}
Summary:        Compatibility provides for OpenMandriva build requirements
License:        MIT
BuildArch:      noarch

Requires:       extra-cmake-modules
Requires:       fedora-logos
Requires:       kactivitymanagerd
Requires:       kde-gtk-config
Requires:       kde-l10n
Requires:       kf6-kiconthemes-devel
Requires:       kf6-qqc2-desktop-style
Requires:       kwin
Requires:       libxml2
Requires:       mesa-libEGL-devel
Requires:       ninja-build
Requires:       OpenEXR-libs
Requires:       python3-build
Requires:       qqc2-breeze-style
Requires:       qt6-qtbase
Requires:       qt6-qtbase-gui
Requires:       qt6-qtdeclarative-devel
Requires:       qt6-qttools
Requires:       xdg-desktop-portal-kde
Requires:       qt6-qtbase-private-devel
Requires:       clang
Requires:       python3-setuptools

Provides:       ninja
Provides:       cmake(Qt6ExamplesAssetDownloaderPrivate)
Provides:       pkgconfig(Qt6QmlAssetDownloader)
Provides:       qt6-qtbase-theme-gtk3
Provides:       cmake(KF6IconWidgets)
Provides:       plasma6-kde-gtk-config
Provides:       openmandriva-kde-translation
Provides:       distro-release-theme
Provides:       qt6-qttools-dbus
Provides:       plasma6-kactivitymanagerd
Provides:       openexrcore
Provides:       plasma6-qqc2-breeze-style
Provides:       cmake(EGL)
Provides:       qt6-qtbase-sql-sqlite
Provides:       plasma6-xdg-desktop-portal-kde
Provides:       qml(org.kde.desktop)
Provides:       libEGL_mesa-devel
Provides:       kwin-aurorae
Provides:       pythondist(build)
Provides:       libxml2-utils
Provides:       cmake(ECM)
Provides:       pkgconfig(dbusmenu-qt6)

%description
Compatibility package that satisfies OpenMandriva-style dependency names
using Fedora package names.

%prep
%build
%install
%files
