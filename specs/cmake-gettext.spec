Name:           cmake-gettext
Version:        1
Release:        1%{?dist}
Summary:        Fedora compatibility alias for cmake(Gettext)
License:        MIT
BuildArch:      noarch

Requires:       gettext-devel

Provides:       cmake(Gettext)

%description
Compatibility package that provides cmake(Gettext) by requiring
Fedora's gettext-devel package. It contains no files.

%prep
%build
%install
%files
