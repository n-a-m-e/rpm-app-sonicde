#!/usr/bin/env bash
set -euo pipefail

OUT=sonicde-specs
ORG=OpenMandrivaAssociation
MATCH='sonic|silver'
ROOT=task-sonicde
COMPAT_PKG=openmandriva-buildrequires-compat
MACROS_FILE="${MACROS_FILE:-macros/openmandriva-compat.macros}"
LOG_FILE="${LOG_FILE:-build-discovery.log}"
VERBOSE="${VERBOSE:-1}"

SONIC_SEARCH_URL='https://api.github.com/search/repositories?q=sonic%20in:name,description+org:OpenMandrivaAssociation&per_page=100'
SILVER_SEARCH_URL='https://api.github.com/search/repositories?q=silver%20in:name,description+org:OpenMandrivaAssociation&per_page=100'

rm -rf "$OUT" .q .seen .deps .repo-map.tsv "$LOG_FILE"
mkdir -p "$OUT"
echo "$ROOT" > .q
: > .seen
: > .deps
: > "$OUT/.task-sonicde.requires"
: > "$LOG_FILE"

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" | tee -a "$LOG_FILE" >&2
}

debug() {
  [[ "$VERBOSE" == 1 ]] && log "DEBUG: $*"
}

norm_key() {
  tr '[:upper:]' '[:lower:]' <<< "$1" | sed -E 's/[^a-z0-9]//g'
}

build_repo_lookup() {
  local tmp url count
  tmp="$(mktemp)"

  log "Building GitHub repo lookup table"
  : > "$tmp"

  for url in "$SONIC_SEARCH_URL" "$SILVER_SEARCH_URL"; do
    log "Fetching GitHub search URL: $url"
    if ! curl --fail --show-error --silent --location --retry 3 --retry-delay 2 \
      -H 'Accept: application/vnd.github+json' \
      -H 'User-Agent: sonicde-build-queue' \
      "$url" >> "$tmp"; then
      log "ERROR: GitHub search failed: $url"
      rm -f "$tmp"
      return 1
    fi
    echo >> "$tmp"
  done

  if ! python3 - "$tmp" > .repo-map.tsv <<'PY'
import json
import re
import sys

path = sys.argv[1]
text = open(path, "r", encoding="utf-8", errors="replace").read()

decoder = json.JSONDecoder()
pos = 0
seen = set()

try:
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
except Exception as exc:
    print(f"repo-map parse failed: {exc}", file=sys.stderr)
    sys.exit(1)
PY
  then
    log "ERROR: Failed to parse GitHub search response"
    rm -f "$tmp"
    return 1
  fi

  rm -f "$tmp"

  count="$(wc -l < .repo-map.tsv | tr -d ' ')"
  cp .repo-map.tsv "$OUT/.repo-map.tsv"
  log "Resolved $count Sonic/Silver OpenMandriva repos into .repo-map.tsv"

  if [[ "$count" == 0 ]]; then
    log "ERROR: GitHub lookup produced no repos"
    return 1
  fi
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
  local r="$1" b url
  mkdir -p "$OUT/$r"

  log "Fetching spec for repo: $r"
  for b in master main rolling; do
    url="$(repo_raw_url "$r" "$b")"
    debug "Trying $url"
    if curl -fsSL "$url" -o "$OUT/$r/$r.spec" 2>"$OUT/$r/.curl-$b.err"; then
      log "Fetched $r spec from branch: $b"
      return 0
    fi
  done

  log "SKIP: Could not fetch root spec for repo: $r"
  if [[ "$VERBOSE" == 1 ]]; then
    for b in master main rolling; do
      [[ -s "$OUT/$r/.curl-$b.err" ]] && sed "s/^/[curl $r $b] /" "$OUT/$r/.curl-$b.err" | tee -a "$LOG_FILE" >&2
    done
  fi

  rm -rf "$OUT/$r"
  return 1
}

parse_spec() {
  local r="$1" raw="$OUT/$r/$r.spec" combined="$OUT/$r/.with-compat.spec" expanded="$OUT/$r/.expanded.spec"

  if [[ -f "$MACROS_FILE" ]] && command -v rpmspec >/dev/null 2>&1; then
    cat "$MACROS_FILE" "$raw" > "$combined"
    if rpmspec --parse "$combined" > "$expanded" 2>"$OUT/$r/.rpmspec-parse.err"; then
      log "Parsed spec with macros: $r"
      return 0
    fi

    log "WARN: rpmspec --parse failed for $r; falling back to raw spec"
    sed "s/^/[rpmspec $r] /" "$OUT/$r/.rpmspec-parse.err" | tee -a "$LOG_FILE" >&2 || true
  else
    log "WARN: macro parsing unavailable for $r; using raw spec"
    [[ -f "$MACROS_FILE" ]] || log "WARN: missing macro file: $MACROS_FILE"
    command -v rpmspec >/dev/null 2>&1 || log "WARN: rpmspec not found in PATH"
  fi

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

  echo "$d"

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
      debug "Resolved dependency '$d' via candidate '$c' key '$key' -> repo '$r'"
      echo "$r"
      return 0
    fi
  done < <(repo_lookup_candidates "$d")

  r="$(norm_dep_name "$d")"
  debug "Unresolved dependency '$d'; falling back to '$r'"
  echo "$r"
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
  if grep -Fxq "$r" .seen .q 2>/dev/null; then
    debug "Already queued/seen repo '$r' from dependency '$d'"
  else
    log "Queue discovery: dependency '$d' -> repo '$r'"
    echo "$r" >> .q
  fi
}

edge() {
  local from="$1" to="$2"
  [[ -z "$from" || -z "$to" || "$from" == "$to" ]] && return 0
  debug "Dependency edge: $from -> $to"
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
  if grep -Fxq "$r" "$OUT/.task-sonicde.requires" 2>/dev/null; then
    debug "Root metapackage already requires: $r"
  else
    log "Root metapackage requires: $r"
    echo "$r" >> "$OUT/.task-sonicde.requires"
  fi
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

  log "Wrote Fedora task metapackage spec: $spec"
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

  if [[ ! -f "$src" ]]; then
    log "No compat spec found at $src; skipping compat-first package"
    return 0
  fi

  mkdir -p "$OUT/$COMPAT_PKG"
  cp "$src" "$dst"
  log "Copied compat spec into generated repo: $dst"
}

build_repo_lookup

while [[ -s .q ]]; do
  r="$(head -n1 .q)"
  sed -i '1d' .q

  if grep -Fxq "$r" .seen 2>/dev/null; then
    debug "Skipping already seen repo: $r"
    continue
  fi

  fetch "$r" || continue
  echo "$r" >> .seen
  parse_spec "$r"

  dep_count=0
  while read -r d; do
    [[ -n "$d" ]] || continue
    dep_count=$((dep_count + 1))
    debug "Dependency from $r: $d"

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

  log "Processed $r dependencies: $dep_count raw dependency tokens"
done

write_task_spec
write_compat_spec
toposort > "$OUT/.order"
cp .seen "$OUT/.seen"
cp .deps "$OUT/.deps"
rm -f .q .seen .deps

log "Final dependency-first order:"
sed 's/^/  /' "$OUT/.order" | tee -a "$LOG_FILE" >&2

(cd "$OUT"; git init -q; git add .; git -c user.name=builder -c user.email=builder@example.invalid commit --allow-empty -qm specs)

url="file://$PWD/$OUT"
commit="$(git -C "$OUT" rev-parse HEAD)"
log "Generated specs git commit: $commit"

if [[ -f "$OUT/$COMPAT_PKG/$COMPAT_PKG.spec" ]]; then
  log "Queueing compat package first: $COMPAT_PKG"
  rpm-build-queue add --package "$COMPAT_PKG" --clone-url "$url" --commit "$commit" --subdir "$COMPAT_PKG" --spec "$COMPAT_PKG.spec"
fi

while read -r p; do
  log "Queueing package: $p"
  rpm-build-queue add --package "$p" --clone-url "$url" --commit "$commit" --subdir "$p" --spec "$p.spec"
done < "$OUT/.order"

log "Build discovery complete"
