#!/usr/bin/env bash
set -euo pipefail

OUT=sonicde-specs
ORG=OpenMandrivaAssociation
MATCH='sonic|silver'
ROOT=task-sonicde
COMPAT_PKG=openmandriva-buildrequires-compat
MACROS_FILE="${MACROS_FILE:-macros/openmandriva-compat.macros}"

SONIC_SEARCH_URL='https://api.github.com/search/repositories?q=sonic%20in:name,description+org:OpenMandrivaAssociation&per_page=100'
SILVER_SEARCH_URL='https://api.github.com/search/repositories?q=silver%20in:name,description+org:OpenMandrivaAssociation&per_page=100'

rm -rf "$OUT" .q .seen .deps .repo-map.tsv
mkdir -p "$OUT"
echo "$ROOT" > .q
: > .seen
: > .deps
: > "$OUT/.task-sonicde.requires"

norm_key() {
  tr '[:upper:]' '[:lower:]' <<< "$1" | sed -E 's/[^a-z0-9]//g'
}

build_repo_lookup() {
  local tmp
  tmp="$(mktemp)"

  {
    curl -fsSL "$SONIC_SEARCH_URL"
    echo
    curl -fsSL "$SILVER_SEARCH_URL"
  } > "$tmp"

  python3 - "$tmp" > .repo-map.tsv <<'PY'
import json
import re
import sys

path = sys.argv[1]
text = open(path, "r", encoding="utf-8", errors="replace").read()

decoder = json.JSONDecoder()
pos = 0
seen = set()

while True:
    while pos < len(text) and text[pos].isspace():
        pos += 1
    if pos >= len(text):
        break

    obj, end = decoder.raw_decode(text, pos)
    pos = end

    for item in obj.get("items", []):
        name = item.get("name") or ""
        url = item.get("html_url") or item.get("clone_url") or item.get("url") or ""
        if not name or not url:
            continue

        key = re.sub(r"[^a-z0-9]", "", name.lower())
        if key in seen:
            continue
        seen.add(key)

        print(f"{key}\t{name}\t{url}")
PY

  rm -f "$tmp"
}

repo_from_key() {
  local key="$1"
  awk -F '\t' -v k="$key" '$1 == k { print $2; exit }' .repo-map.tsv
}

repo_url_from_name() {
  local name="$1" key
  key="$(norm_key "$name")"
  awk -F '\t' -v k="$key" '$1 == k { print $3; exit }' .repo-map.tsv
}

repo_raw_url() {
  local r="$1" b="$2" url repo_name
  url="$(repo_url_from_name "$r")"

  if [[ "$url" =~ ^https://github.com/([^/]+)/([^/]+)$ ]]; then
    repo_name="${BASH_REMATCH[2]}"
    printf 'https://raw.githubusercontent.com/%s/%s/%s/%s.spec\n' "${BASH_REMATCH[1]}" "$repo_name" "$b" "$repo_name"
  else
    printf 'https://raw.githubusercontent.com/%s/%s/%s/%s.spec\n' "$ORG" "$r" "$b" "$r"
  fi
}

fetch() {
  local r="$1" b
  mkdir -p "$OUT/$r"
  for b in master main rolling; do
    curl -fsSL "$(repo_raw_url "$r" "$b")" -o "$OUT/$r/$r.spec" 2>/dev/null && return 0
  done
  rm -rf "$OUT/$r"
  return 1
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

norm_dep_name() {
  local d="$1"

  d="${d%-devel}"
  d="${d#pkgconfig(}"
  d="${d#cmake(}"
  d="${d%)}"
  d="${d#lib64}"
  d="${d#lib}"

  echo "$d"
}

repo_lookup_candidates() {
  local d="$1" base

  d="$(norm_dep_name "$d")"

  [[ "$d" == task-sonicde-minimal ]] && { echo "$ROOT"; return; }

  # Try the dependency as-is first.
  echo "$d"

  # Then try generic conversions from package names to repo-style names.
  base="${d#SonicFrameworks}"
  [[ "$base" != "$d" ]] && echo "sonic-frameworks-$base"

  base="${d#SonicDE}"
  [[ "$base" != "$d" ]] && echo "sonic-$base"

  base="${d#Sonic}"
  [[ "$base" != "$d" ]] && echo "sonic-$base"

  base="${d#Silver}"
  [[ "$base" != "$d" ]] && echo "silver-$base"
}

repo() {
  local d="$1" c key r

  while read -r c; do
    [[ -n "$c" ]] || continue
    key="$(norm_key "$c")"
    r="$(repo_from_key "$key")"
    if [[ -n "$r" ]]; then
      echo "$r"
      return 0
    fi
  done < <(repo_lookup_candidates "$d")

  # Fallback to cleaned dependency so unresolved items remain visible.
  norm_dep_name "$d"
}

clean() {
  local x="$1" r="$2"

  x="${x//%\{name\}/$r}"
  x="${x//%\{?_isa\}/}"
  x="${x//%\{EVRD\}/}"
  x="${x//%\{_lib\}/lib}"
  x="${x//%_lib/lib}"

  sed -E 's/#.*//;s/%\{[^}]+\}//g;s/[<>=].*//;s/^[[:space:]("'"'"']+//;s/[[:space:],)"'"'"']+$//' <<< "$x" |
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
    l="${l#\(}"
    l="${l%\)}"
    l="${l%% if *}"
    l="${l%% or *}"
    l="${l%% and *}"

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

  cat > "$spec" <<'EOF2'
Name:           task-sonicde
Version:        1
Release:        1%{?dist}
Summary:        SonicDE desktop environment metapackage
License:        MIT
BuildArch:      noarch

EOF2

  while read -r p; do
    [[ -n "$p" ]] && printf 'Requires:       %s\n' "$p" >> "$spec"
  done < "$OUT/.task-sonicde.requires"

  cat >> "$spec" <<'EOF2'

%description
Metapackage that installs the SonicDE and Silver packages selected from the
OpenMandriva task-sonicde dependency set.

%prep
%build
%install
%files
EOF2
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
      # Only include edges where both endpoints were actually fetched.
      # This prevents GitHub-search matches without a root .spec from being
      # queued and then failing as Missing subdir.
      if (!(dep in node) || !(pkg in node)) next
      children[pkg]=children[pkg] SUBSEP dep
    }
    END {
      for (n in node) visit(n)
    }
  ' .seen .deps
}

write_compat_spec() {
  local src="specs/$COMPAT_PKG.spec" dst="$OUT/$COMPAT_PKG/$COMPAT_PKG.spec"

  [[ -f "$src" ]] || return 0

  mkdir -p "$OUT/$COMPAT_PKG"
  cp "$src" "$dst"
}

build_repo_lookup

while [[ -s .q ]]; do
  r="$(head -n1 .q)"
  sed -i '1d' .q

  grep -Fxq "$r" .seen 2>/dev/null && continue

  # Important: only mark repos seen after fetch succeeds. Otherwise the
  # topological order may include repos that never made it into $OUT.
  fetch "$r" || continue
  echo "$r" >> .seen
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
write_compat_spec
toposort > "$OUT/.order"
rm -f .q .seen .deps

(cd "$OUT"; git init -q; git add .; git -c user.name=builder -c user.email=builder@example.invalid commit --allow-empty -qm specs)

url="file://$PWD/$OUT"
commit="$(git -C "$OUT" rev-parse HEAD)"

if [[ -f "$OUT/$COMPAT_PKG/$COMPAT_PKG.spec" ]]; then
  rpm-build-queue add --package "$COMPAT_PKG" --clone-url "$url" --commit "$commit" --subdir "$COMPAT_PKG" --spec "$COMPAT_PKG.spec"
fi

while read -r p; do
  rpm-build-queue add --package "$p" --clone-url "$url" --commit "$commit" --subdir "$p" --spec "$p.spec"
done < "$OUT/.order"
