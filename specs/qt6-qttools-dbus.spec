Name:           qt6-qttools-dbus
Version:        1
Release:        1%{?dist}
Summary:        Fedora compatibility alias for qt6-qttools-dbus
License:        MIT
BuildArch:      noarch

Requires:       qt6-qttools

Provides:       qt6-qttools-dbus

%description
Compatibility package that provides qt6-qttools-dbus by requiring
Fedora's qt6-qttools package. It contains no files.

%prep
%build
%install
%files
