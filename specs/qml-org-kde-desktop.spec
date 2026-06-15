Name:           qml-org-kde-desktop
Version:        1
Release:        1%{?dist}
Summary:        Fedora compatibility alias for qml(org.kde.desktop)
License:        MIT
BuildArch:      noarch

Requires:       kf6-qqc2-desktop-style

Provides:       qml(org.kde.desktop)

%description
Compatibility package that provides qml(org.kde.desktop) by requiring
Fedora's kf6-qqc2-desktop-style package. It contains no files.

%prep
%build
%install
%files
