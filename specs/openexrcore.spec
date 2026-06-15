Name:           openexrcore
Version:        1
Release:        1%{?dist}
Summary:        Fedora compatibility alias for openexrcore
License:        MIT
BuildArch:      noarch

Requires:       OpenEXR

Provides:       openexrcore

%description
Compatibility package that provides openexrcore by requiring
Fedora's OpenEXR package. It contains no files.

%prep
%build
%install
%files
