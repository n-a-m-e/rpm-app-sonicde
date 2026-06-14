#!/usr/bin/env bash
set -euo pipefail

OUT=sonicde-specs
ORG=OpenMandrivaAssociation
ROOT=task-sonicde
COMPAT=openmandriva-buildrequires-compat
MACROS_FILE="${MACROS_FILE:-macros/openmandriva-compat.macros}"
LOG="${LOG:-build-discovery.log}"

SEARCHES=(
  'https://api.github.com/search/repositories?q=sonic%20in:name,description+org:OpenMandrivaAssociation&per_page=100'
  'https://api.github.com/search/repositories?q=silver%20in:name,description+org:OpenMandrivaAssociation&per_page=100'
)

rm -rf "$OUT" .q .seen .deps .repos.tsv "$LOG"
mkdir -p "$OUT"
printf '%s\n' "$ROOT" > .q
: > .seen
: > .deps
: > "$OUT/.task-sonicde.requires"
: > "$LOG"

log() { printf '%s\n' "$*" | tee -a "$LOG" >&2; }
key() { tr '[:upper:]' '[:lower:]' <<< "$1" | sed -E 's/[^a-z0-9]//g'; }
wanted() { [[ "${1:-}" =~ [Ss]onic|[Ss]ilver ]]; }

make_repo_map() {
  local tmp u
  tmp="$(mktemp)"
  : > "$tmp"

  for u in "${SEARCHES[@]}"; do
    log "github lookup: $u"
    curl -fsSL --retry 3 --retry-delay 2 \
      -H 'Accept: application/vnd.github+json' \
      -H 'User-Agent: sonicde-build-queue' \
      "$u" >> "$tmp"
    echo >> "$tmp"
  done

  python3 - "$tmp" > .repos.tsv <<'PY'
import json, re, sys
s = open(sys.argv[1], encoding="utf-8", errors="replace").read()
dec, pos, seen = json.JSONDecoder(), 0, set()
while True:
    while pos < len(s) and s[pos].isspace(): pos += 1
    if pos >= len(s): break
    obj, pos = dec.raw_decode(s, pos)
    for it in obj.get("items", []):
        name = it.get("name") or ""
        url = it.get("html_url") or ""
        k = re.sub(r"[^a-z0-9]", "", name.lower())
        if name and url and k not in seen:
            seen.add(k)
            print(f"{k}\t{name}\t{url}")
PY

  rm -f "$tmp"
  cp .repos.tsv "$OUT/.repo-map.tsv"
  log "github lookup repos: $(wc -l < .repos.tsv)"
}

repo_by_key() { awk -F '\t' -v k="$1" '$1==k{print $2; exit}' .repos.tsv; }
url_by_repo() { awk -F '\t' -v k="$(key "$1")" '$1==k{print $3; exit}' .repos.tsv; }

dep_base() {
  local d="$1"
  d="${d%-devel}"
  d="${d#pkgconfig(}"; d="${d#cmake(}"; d="${d%)}"
  d="${d#lib64}"; d="${d#lib}"
  printf '%s\n' "$d"
}

repo_candidates() {
  local d b
  d="$(dep_base "$1")"
  [[ "$d" == task-sonicde-minimal ]] && { echo "$ROOT"; return; }

  echo "$d"
  b="${d#SonicFrameworks}"; [[ "$b" != "$d" ]] && echo "sonic-frameworks-$b"
  b="${d#SonicDE}";         [[ "$b" != "$d" ]] && echo "sonic-$b"
  b="${d#Sonic}";           [[ "$b" != "$d" ]] && echo "sonic-$b"
  b="${d#Silver}";          [[ "$b" != "$d" ]] && echo "silver-$b"
}

repo() {
  local c r
  while read -r c; do
    r="$(repo_by_key "$(key "$c")")"
    [[ -n "$r" ]] && { echo "$r"; return; }
  done < <(repo_candidates "$1")
  dep_base "$1"
}

raw_url() {
  local r="$1" b="$2" u repo_name
  u="$(url_by_repo "$r")"

  if [[ "$u" =~ ^https://github.com/([^/]+)/([^/]+)$ ]]; then
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
    if curl -fsSL "$(raw_url "$r" "$b")" -o "$OUT/$r/$r.spec" 2>/dev/null; then
      log "fetched: $r ($b)"
      return 0
    fi
  done

  log "skip no spec: $r"
  rm -rf "$OUT/$r"
  return 1
}

parse_spec() {
  local r="$1" spec="$OUT/$r/$r.spec" expanded="$OUT/$r/.expanded.spec"
  if [[ -f "$MACROS_FILE" ]] && command -v rpmspec >/dev/null 2>&1; then
    cat "$MACROS_FILE" "$spec" > "$OUT/$r/.with-compat.spec"
    rpmspec --parse "$OUT/$r/.with-compat.spec" > "$expanded" 2>"$OUT/$r/.rpmspec.err" && return
    log "warn rpmspec parse failed: $r"
  fi
  cp "$spec" "$expanded"
}

clean_dep() {
  local x="$1" r="$2"
  x="${x//%\{name\}/$r}"
  x="${x//%\{?_isa\}/}"
  x="${x//%\{EVRD\}/}"
  x="${x//%\{_lib\}/lib}"
  x="${x//%_lib/lib}"
  sed -E 's/#.*//;s/%\{[^}]+\}//g;s/[<>=].*//;s/^[[:space:]("'"'"']+//;s/[[:space:],)"'"'"']+$//' <<< "$x" | awk '{print $1}'
}

deps() {
  local r="$1" l w
  awk 'BEGIN{IGNORECASE=1}/^[[:space:]]*(Requires|BuildRequires|Recommends|Suggests)[[:space:]]*:/{sub(/^[^:]*:[[:space:]]*/,"");print}' "$OUT/$r/.expanded.spec" |
  while read -r l; do
    l="${l#\(}"; l="${l%\)}"
    l="${l%% if *}"; l="${l%% or *}"; l="${l%% and *}"

    if [[ "$l" =~ [[:space:]](>=|<=|=|>|<)[[:space:]] ]]; then
      clean_dep "$l" "$r"
    else
      for w in $l; do clean_dep "$w" "$r"; done
    fi
  done
}

add_queue() {
  local d="$1" r
  wanted "$d" || return
  r="$(repo "$d")"
  wanted "$r" || return
  grep -Fxq "$r" .seen .q 2>/dev/null || { log "discover: $d -> $r"; echo "$r" >> .q; }
}

add_root_req() {
  local d="$1" r
  wanted "$d" || return
  r="$(repo "$d")"
  [[ "$r" == "$ROOT" ]] && return
  wanted "$r" || return
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

copy_compat() {
  [[ -f "specs/$COMPAT.spec" ]] || return
  mkdir -p "$OUT/$COMPAT"
  cp "specs/$COMPAT.spec" "$OUT/$COMPAT/$COMPAT.spec"
}

toposort() {
  python3 - .seen .deps > "$OUT/.order" <<'PY'
import sys
from collections import defaultdict

seen_file, deps_file = sys.argv[1], sys.argv[2]
nodes = [x.strip() for x in open(seen_file) if x.strip()]
node_set = set(nodes)
deps = defaultdict(set)

for line in open(deps_file):
    line = line.rstrip("\n")
    if not line:
        continue
    dep, pkg = line.split("\t", 1)
    if dep in node_set and pkg in node_set and dep != pkg:
        deps[pkg].add(dep)

done, visiting, out = set(), set(), []

def visit(n):
    if n in done:
        return
    if n in visiting:
        print(f"dependency cycle involving {n}", file=sys.stderr)
        return
    visiting.add(n)
    for d in sorted(deps[n]):
        visit(d)
    visiting.remove(n)
    done.add(n)
    out.append(n)

for n in nodes:
    visit(n)

print("\n".join(out))
PY
}

make_repo_map

while [[ -s .q ]]; do
  r="$(head -n1 .q)"
  sed -i '1d' .q
  grep -Fxq "$r" .seen 2>/dev/null && continue

  fetch "$r" || continue
  echo "$r" >> .seen
  parse_spec "$r"

  while read -r d; do
    [[ -n "$d" ]] || continue

    [[ "$r" == "$ROOT" ]] && add_root_req "$d"

    wanted "$d" || continue
    rr="$(repo "$d")"
    wanted "$rr" || continue

    add_queue "$d"
    [[ "$rr" != "$r" ]] && printf '%s\t%s\n' "$rr" "$r" >> .deps
  done < <(deps "$r")
done

write_task_spec
copy_compat
toposort
cp .seen "$OUT/.seen"
cp .deps "$OUT/.deps"
rm -f .q .seen .deps .repos.tsv

(cd "$OUT"; git init -q; git add .; git -c user.name=builder -c user.email=builder@example.invalid commit --allow-empty -qm specs)

url="file://$PWD/$OUT"
commit="$(git -C "$OUT" rev-parse HEAD)"

if [[ -f "$OUT/$COMPAT/$COMPAT.spec" ]]; then
  log "queue: $COMPAT"
  rpm-build-queue add --package "$COMPAT" --clone-url "$url" --commit "$commit" --subdir "$COMPAT" --spec "$COMPAT.spec"
fi

while read -r p; do
  log "queue: $p"
  rpm-build-queue add --package "$p" --clone-url "$url" --commit "$commit" --subdir "$p" --spec "$p.spec"
done < "$OUT/.order"
