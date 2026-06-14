#!/usr/bin/env bash
set -euo pipefail

OUT=sonicde-specs
ORG=OpenMandrivaAssociation
MATCH='sonic|silver'
ROOT=task-sonicde

rm -rf "$OUT" .q .seen
mkdir -p "$OUT"
echo "$ROOT" > .q
: > .seen
: > "$OUT/.order"
: > "$OUT/.task-sonicde.requires"

fetch() {
  mkdir -p "$OUT/$1"
  for b in master main rolling; do
    curl -fsSL "https://raw.githubusercontent.com/$ORG/$1/$b/$1.spec" -o "$OUT/$1/$1.spec" 2>/dev/null && {
      echo "$1" >> "$OUT/.order"
      return 0
    }
  done
  rm -rf "$OUT/$1"
  return 1
}

camel() {
  sed -E 's/([a-z0-9])([A-Z])/\1-\2/g;s/([A-Z]+)([A-Z][a-z])/\1-\2/g' <<< "$1" | tr A-Z a-z
}

repo() {
  d="${1%-devel}"
  [[ "$d" == task-sonicde-minimal ]] && { echo "$ROOT"; return; }
  [[ "$d" == sonic-* || "$d" == silver-* ]] && { echo "$d"; return; }

  if [[ "$d" =~ ^libSonicFrameworks(.+) ]]; then
    echo "sonic-frameworks-$(camel "${BASH_REMATCH[1]}")"
  elif [[ "$d" =~ ^libSonicDE(.+) ]]; then
    echo "sonic-$(camel "${BASH_REMATCH[1]}")"
  elif [[ "$d" == libSonicDE ]]; then
    echo sonic-interface-libraries
  else
    echo "$d"
  fi
}

clean() {
  x="${1//%\{name\}/$2}"
  x="${x//%\{?_isa\}/}"
  x="${x//%\{EVRD\}/}"
  x="${x//%\{_lib\}/lib}"
  sed -E 's/#.*//;s/%\{[^}]+\}//g;s/[<>=].*//;s/^[[:space:]("'\'']+//;s/[[:space:],)"'\'']+$//' <<< "$x" | awk '{print $1}'
}

add_root_require() {
  local d="$1" r
  [[ -n "$d" ]] || return 0
  grep -Eiq "$MATCH" <<< "$d" || return 0
  r="$(repo "$d")"
  [[ "$r" == "$ROOT" ]] && return 0
  grep -Eiq "$MATCH" <<< "$r" || return 0
  grep -Fxq "$r" "$OUT/.task-sonicde.requires" 2>/dev/null || echo "$r" >> "$OUT/.task-sonicde.requires"
}

add() {
  d="$1"
  [[ -n "$d" ]] || return 0
  grep -Eiq "$MATCH" <<< "$d" || return 0
  r="$(repo "$d")"
  grep -Eiq "$MATCH" <<< "$r" || return 0
  grep -Fxq "$r" .seen .q 2>/dev/null || echo "$r" >> .q
}

deps() {
  r="$1"
  awk 'BEGIN{IGNORECASE=1}/^[[:space:]]*(Requires|BuildRequires|Recommends|Suggests)[[:space:]]*:/{sub(/^[^:]*:[[:space:]]*/,"");print}' "$OUT/$r/$r.spec" |
  while read -r l; do
    [[ "$l" =~ ^%mklibname[[:space:]]+-d[[:space:]]+([^[:space:]]+) ]] && { echo "${BASH_REMATCH[1]}"; continue; }

    l="${l#\(}"; l="${l%\)}"
    l="${l%% if *}"; l="${l%% or *}"; l="${l%% and *}"

    if [[ "$l" =~ [[:space:]](>=|<=|=|>|<)[[:space:]] ]]; then
      echo "$(clean "$l" "$r")"
    else
      for w in $l; do echo "$(clean "$w" "$r")"; done
    fi
  done
}

write_task_spec() {
  local spec="$OUT/$ROOT/$ROOT.spec"

  sort -u "$OUT/.task-sonicde.requires" -o "$OUT/.task-sonicde.requires"

  cat > "$spec" <<'EOF'
Name:           task-sonicde
Version:        1
Release:        1%{?dist}
Summary:        SonicDE desktop environment metapackage
License:        MIT
BuildArch:      noarch

EOF

  while read -r pkg; do
    [[ -n "$pkg" ]] && printf 'Requires:       %s\n' "$pkg" >> "$spec"
  done < "$OUT/.task-sonicde.requires"

  cat >> "$spec" <<'EOF'

%description
Metapackage that installs the SonicDE and Silver packages selected from the
OpenMandriva task-sonicde dependency set.

%prep

%build

%install

%files
EOF
}

while [[ -s .q ]]; do
  r="$(head -n1 .q)"
  sed -i '1d' .q

  grep -Fxq "$r" .seen 2>/dev/null && continue
  echo "$r" >> .seen

  fetch "$r" || continue

  deps "$r" | while read -r d; do
    if [[ "$r" == "$ROOT" ]]; then
      grep -Eiq "$MATCH" <<< "$d" || continue
      add_root_require "$d"
    fi
    add "$d"
  done
done

write_task_spec
rm -f .q .seen

(cd "$OUT"; git init -q; git add .; git -c user.name=builder -c user.email=builder@example.invalid commit --allow-empty -qm specs)

url="file://$PWD/$OUT"
commit="$(git -C "$OUT" rev-parse HEAD)"

tac "$OUT/.order" | while read -r p; do
  rpm-build-queue add --package "$p" --clone-url "$url" --commit "$commit" --subdir "$p" --spec "$p.spec"
done
