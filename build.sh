#!/usr/bin/env bash
set -euo pipefail

OUT=sonicde-specs
ORG=OpenMandrivaAssociation
MATCH='sonic|silver'
ROOT=task-sonicde
MACROS_FILE="${MACROS_FILE:-macros/openmandriva-compat.macros}"

rm -rf "$OUT" .q .seen .deps
mkdir -p "$OUT"
echo "$ROOT" > .q
: > .seen
: > .deps
: > "$OUT/.task-sonicde.requires"

fetch() {
  mkdir -p "$OUT/$1"
  for b in master main rolling; do
    curl -fsSL "https://raw.githubusercontent.com/$ORG/$1/$b/$1.spec" -o "$OUT/$1/$1.spec" 2>/dev/null && return 0
  done
  rm -rf "$OUT/$1"
  return 1
}

camel() {
  sed -E 's/([a-z0-9])([A-Z])/\1-\2/g;s/([A-Z]+)([A-Z][a-z])/\1-\2/g' <<< "$1" | tr A-Z a-z
}

parse_spec() {
  local r="$1" raw="$OUT/$r/$r.spec" combined="$OUT/$r/.with-compat.spec" expanded="$OUT/$r/.expanded.spec"

  if [[ -f "$MACROS_FILE" ]] && command -v rpmspec >/dev/null 2>&1; then
    cat "$MACROS_FILE" "$raw" > "$combined"
    if rpmspec --parse "$combined" > "$expanded" 2>"$OUT/$r/.rpmspec-parse.err"; then
      return 0
    fi
  fi

  # Fallback: keep crawling even if rpmspec is unavailable or a remote spec
  # needs sources/macros not present during queue discovery.
  cp "$raw" "$expanded"
}

repo() {
  local d="$1" base

  d="${d%-devel}"
  d="${d#pkgconfig(}"; d="${d#cmake(}"; d="${d%)}"

  [[ "$d" == task-sonicde-minimal ]] && { echo "$ROOT"; return; }
  [[ "$d" == sonic-* || "$d" == silver-* ]] && { echo "$d"; return; }

  # Repo discovery still needs to map package names to OpenMandriva repo names.
  # Keep this generic: strip lib/lib64 package prefixes, then convert Sonic*/Silver*
  # CamelCase names to lower kebab repo names.
  base="$d"
  base="${base#lib64}"
  base="${base#lib}"

  if [[ "$base" =~ ^SonicFrameworks(.+) ]]; then
    echo "sonic-frameworks-$(camel "${BASH_REMATCH[1]}")"
  elif [[ "$base" =~ ^SonicDE(.+) ]]; then
    echo "sonic-$(camel "${BASH_REMATCH[1]}")"
  elif [[ "$base" == SonicDE ]]; then
    echo sonic-interface-libraries
  elif [[ "$base" =~ ^Sonic(.+) ]]; then
    echo "sonic-$(camel "${BASH_REMATCH[1]}")"
  elif [[ "$base" =~ ^Silver(.+) ]]; then
    echo "silver-$(camel "${BASH_REMATCH[1]}")"
  else
    echo "$d"
  fi
}

clean() {
  local x="$1" r="$2"

  x="${x//%\{name\}/$r}"
  x="${x//%\{?_isa\}/}"
  x="${x//%\{EVRD\}/}"
  x="${x//%\{_lib\}/lib}"
  x="${x//%_lib/lib}"

  sed -E 's/#.*//;s/%\{[^}]+\}//g;s/[<>=].*//;s/^[[:space:]("'\'']+//;s/[[:space:],)"'\'']+$//' <<< "$x" |
    awk '{print $1}'
}

is_wanted() {
  [[ -n "$1" ]] && grep -Eiq "$MATCH" <<< "$1"
}

add() {
  local d="$1" r
  is_wanted "$d" || return 0
  r="$(repo "$d")"
  is_wanted "$r" || return 0
  grep -Fxq "$r" .seen .q 2>/dev/null || echo "$r" >> .q
}

edge() {
  local from="$1" to="$2"
  [[ -z "$from" || -z "$to" || "$from" == "$to" ]] && return 0
  printf '%s\t%s\n' "$from" "$to" >> .deps
}

deps() {
  local r="$1" spec="$OUT/$r/.expanded.spec"

  awk 'BEGIN{IGNORECASE=1}/^[[:space:]]*(Requires|BuildRequires|Recommends|Suggests)[[:space:]]*:/{sub(/^[^:]*:[[:space:]]*/,"");print}' "$spec" |
  while read -r l; do
    l="${l#\(}"; l="${l%\)}"
    l="${l%% if *}"; l="${l%% or *}"; l="${l%% and *}"

    if [[ "$l" =~ [[:space:]](>=|<=|=|>|<)[[:space:]] ]]; then
      clean "$l" "$r"
    else
      for w in $l; do clean "$w" "$r"; done
    fi
  done
}

add_root_require() {
  local d="$1" r
  is_wanted "$d" || return 0
  r="$(repo "$d")"
  [[ "$r" == "$ROOT" ]] && return 0
  is_wanted "$r" || return 0
  grep -Fxq "$r" "$OUT/.task-sonicde.requires" 2>/dev/null || echo "$r" >> "$OUT/.task-sonicde.requires"
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

  while read -r p; do
    [[ -n "$p" ]] && printf 'Requires:       %s\n' "$p" >> "$spec"
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

toposort() {
  awk -F '\t' '
    function visit(n) {
      if (done[n]) return
      if (temp[n]) {
        print "dependency cycle involving " n > "/dev/stderr"
        return
      }
      temp[n]=1
      split(children[n], c, SUBSEP)
      for (i in c) if (c[i] != "") visit(c[i])
      temp[n]=0
      done[n]=1
      print n
    }
    FNR==NR {
      if ($0 != "") node[$0]=1
      next
    }
    {
      dep=$1; pkg=$2
      if (dep == "" || pkg == "" || dep == pkg) next
      node[dep]=1; node[pkg]=1
      children[pkg]=children[pkg] SUBSEP dep
    }
    END {
      for (n in node) visit(n)
    }
  ' .seen .deps
}

while [[ -s .q ]]; do
  r="$(head -n1 .q)"
  sed -i '1d' .q

  grep -Fxq "$r" .seen 2>/dev/null && continue
  echo "$r" >> .seen

  fetch "$r" || continue
  parse_spec "$r"

  while read -r d; do
    [[ -n "$d" ]] || continue

    if [[ "$r" == "$ROOT" ]]; then
      is_wanted "$d" || continue
      add_root_require "$d"
    fi

    is_wanted "$d" || continue
    dep_repo="$(repo "$d")"
    is_wanted "$dep_repo" || continue

    add "$d"
    edge "$dep_repo" "$r"
  done < <(deps "$r")
done

write_task_spec
toposort > "$OUT/.order"
rm -f .q .seen .deps

(cd "$OUT"; git init -q; git add .; git -c user.name=builder -c user.email=builder@example.invalid commit --allow-empty -qm specs)

url="file://$PWD/$OUT"
commit="$(git -C "$OUT" rev-parse HEAD)"

while read -r p; do
  rpm-build-queue add --package "$p" --clone-url "$url" --commit "$commit" --subdir "$p" --spec "$p.spec"
done < "$OUT/.order"
