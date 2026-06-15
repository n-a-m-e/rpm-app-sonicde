Name:           distro-release-theme
Version:        1
Release:        1%{?dist}
Summary:        Fedora compatibility alias for distro-release-theme
License:        MIT
BuildArch:      noarch

Requires:       fedora-logos

Provides:       distro-release-theme

%description
Compatibility package that provides distro-release-theme by requiring
Fedora's fedora-logos package. It contains no files.

%prep
%build
%install
%files
