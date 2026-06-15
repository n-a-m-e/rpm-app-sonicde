Name:           openmandriva-kde-translation
Version:        1
Release:        1%{?dist}
Summary:        Fedora compatibility alias for openmandriva-kde-translation
License:        MIT
BuildArch:      noarch

Requires:       kde-l10n

Provides:       openmandriva-kde-translation

%description
Compatibility package that provides openmandriva-kde-translation by requiring
Fedora's kde-l10n package. It contains no files.

%prep
%build
%install
%files
