Name:           kf6-kauth-devel
Version:        1
Release:        1%{?dist}
Summary:        Fedora compatibility alias for kf6-kauth-devel
License:        MIT
BuildArch:      noarch

Requires:       libSonicFrameworksAuth-devel

Provides:       kf6-kauth-devel

%description
Compatibility package that provides kf6-kauth-devel by requiring
Fedora's libSonicFrameworksAuth-devel package. It contains no files.

%prep
%build
%install
%files
