Name:           plasma6-kactivitymanagerd
Version:        1
Release:        1%{?dist}
Summary:        Fedora compatibility alias for plasma6-kactivitymanagerd
License:        MIT
BuildArch:      noarch

Requires:       kactivitymanagerd

Provides:       plasma6-kactivitymanagerd

%description
Compatibility package that provides plasma6-kactivitymanagerd by requiring
Fedora's kactivitymanagerd package. It contains no files.

%prep
%build
%install
%files
