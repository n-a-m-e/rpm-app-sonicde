Name:           kwin-aurorae
Version:        1
Release:        1%{?dist}
Summary:        Fedora compatibility alias for kwin-aurorae
License:        MIT
BuildArch:      noarch

Requires:       kwin

Provides:       kwin-aurorae

%description
Compatibility package that provides kwin-aurorae by requiring
Fedora's kwin package. It contains no files.

%prep
%build
%install
%files
