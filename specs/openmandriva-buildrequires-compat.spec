Name:           openmandriva-buildrequires-compat
Version:        1
Release:        1%{?dist}
Summary:        Compatibility provides for OpenMandriva build requirements
License:        MIT
BuildArch:      noarch

Requires:       extra-cmake-modules
Requires:       kf6-kiconthemes-devel
Requires:       libxml2
Requires:       mesa-libEGL-devel
Requires:       ninja-build
Requires:       python3-build
Requires:       qt6-qtbase
Requires:       qt6-qtbase-gui
Requires:       qt6-qtdeclarative-devel
Requires:       xdg-desktop-portal-kde
Requires:       qt6-qtbase-private-devel
Requires:       clang
Requires:       python3-setuptools

Provides:       ninja
Provides:       cmake(Qt6ExamplesAssetDownloaderPrivate)
Provides:       pkgconfig(Qt6QmlAssetDownloader)
Provides:       qt6-qtbase-theme-gtk3
Provides:       cmake(KF6IconWidgets)
Provides:       cmake(EGL)
Provides:       qt6-qtbase-sql-sqlite
Provides:       plasma6-xdg-desktop-portal-kde
Provides:       libEGL_mesa-devel
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
