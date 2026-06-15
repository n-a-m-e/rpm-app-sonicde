Name:           plasma6-kde-gtk-config
Version:        1
Release:        1%{?dist}
Summary:        Fedora compatibility alias for plasma6-kde-gtk-config
License:        MIT
BuildArch:      noarch

Requires:       kde-gtk-config

Provides:       plasma6-kde-gtk-config

%description
Compatibility package that provides plasma6-kde-gtk-config by requiring
Fedora's kde-gtk-config package. It contains no files.

%prep
%build
%install
%files
