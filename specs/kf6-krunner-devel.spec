Name:           kf6-krunner-devel
Version:        1
Release:        1%{?dist}
Summary:        Fedora compatibility alias for kf6-krunner-devel
License:        MIT
BuildArch:      noarch

Requires:       libSonicFrameworksRunner-devel

Provides:       kf6-krunner-devel

%description
Compatibility package that provides kf6-krunner-devel by requiring
Fedora's libSonicFrameworksRunner-devel package. It contains no files.

%prep
%build
%install
%files
