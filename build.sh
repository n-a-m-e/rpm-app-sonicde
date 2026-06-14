#!/usr/bin/env bash
set -euo pipefail

OUT=sonicde-specs
ROOT=task-sonicde
COMPAT=openmandriva-buildrequires-compat
MACROS_FILE="${MACROS_FILE:-macros/openmandriva-compat.macros}"
PATCH_DIR="${PATCH_DIR:-patches}"
LOG="${LOG:-build-discovery.log}"

SEARCHES=(
  'https://api.github.com/search/repositories?q=sonic%20in:name,description+org:OpenMandrivaAssociation&per_page=100'
  'https://api.github.com/search/repositories?q=silver%20in:name,description+org:OpenMandrivaAssociation&per_page=100'
)

rm -rf "$OUT" .repos.tsv .providers.tsv .processed .deps .applied-patches "$LOG"
mkdir -p "$OUT"
: > .providers.tsv
: > .processed
: > .deps
: > .applied-patches
: > "$OUT/.task-sonicde.requires"
: > "$LOG"

log(){ printf '[%s] %s\n' "$(date -u +'%H:%M:%S')" "$*" | tee -a "$LOG" >&2; }
die(){ log "ERROR: $*"; exit 1; }
key(){ tr '[:upper:]' '[:lower:]' <<< "$1" | sed -E 's/[^a-z0-9]//g'; }
wanted(){ [[ "${1:-}" =~ [Ss]onic|[Ss]ilver ]]; }

need(){
  command -v curl >/dev/null || die "curl missing"
  command -v python3 >/dev/null || die "python3 missing"
  command -v rpmspec >/dev/null || die "rpmspec missing"
  command -v patch >/dev/null || die "patch missing"
  [[ -f "$MACROS_FILE" ]] || die "macro file missing: $MACROS_FILE"
  [[ -d "$PATCH_DIR" ]] || log "No patch directory found: $PATCH_DIR"
  [[ -f "specs/$COMPAT.spec" ]] || die "compat spec missing: specs/$COMPAT.spec"
}

github_repos(){
  local tmp u
  tmp="$(mktemp)"
  : > "$tmp"

  log "GitHub lookup"
  for u in "${SEARCHES[@]}"; do
    curl -fsSL --retry 3 --retry-delay 2 \
      -H 'Accept: application/vnd.github+json' \
      -H 'User-Agent: sonicde-build-queue' \
      "$u" >> "$tmp" || die "GitHub lookup failed: $u"
    echo >> "$tmp"
  done

  python3 - "$tmp" > .repos.tsv <<'PY'
import json, re, sys

def keep_repo(name):
    n = name.lower()
    return n == "task-sonicde" or n.startswith("sonic") or n.startswith("silver")

s = open(sys.argv[1], encoding="utf-8", errors="replace").read()
dec, pos, seen = json.JSONDecoder(), 0, set()

while True:
    while pos < len(s) and s[pos].isspace():
        pos += 1
    if pos >= len(s):
        break

    obj, pos = dec.raw_decode(s, pos)

    for it in obj.get("items", []):
        name, url = it.get("name") or "", it.get("html_url") or ""
        if not name or not url or not keep_repo(name):
            continue

        k = re.sub(r"[^a-z0-9]", "", name.lower())
        if k in seen:
            continue

        seen.add(k)
        print(f"{k}\t{name}\t{url}")
PY

  rm -f "$tmp"
  [[ -s .repos.tsv ]] || die "GitHub lookup returned no relevant Sonic/Silver repos"

  awk -F '\t' '{print $2}' .repos.tsv | sort -u > "$OUT/.all-repos"
  cp .repos.tsv "$OUT/.repo-map.tsv"

  log "Relevant repos found: $(wc -l < "$OUT/.all-repos")"
}

repo_url(){
  awk -F '\t' -v k="$(key "$1")" '$1==k{print $3; exit}' .repos.tsv
}

raw_url(){
  local repo="$1" branch="$2" u name
  u="$(repo_url "$repo")"
  [[ "$u" =~ ^https://github.com/([^/]+)/([^/]+)$ ]] || die "bad/missing GitHub URL for $repo"
  name="${BASH_REMATCH[2]}"
  printf 'https://raw.githubusercontent.com/%s/%s/%s/%s.spec\n' "${BASH_REMATCH[1]}" "$name" "$branch" "$name"
}

apply_repo_patch(){
  local repo="$1" patch_file="$PATCH_DIR/$repo.spec.patch"

  [[ -f "$patch_file" ]] || return 0

  log "Applying patch: $patch_file"
  patch -d "$OUT" --batch --forward -p1 < "$patch_file" > "$OUT/$repo/.patch.log" 2>&1 || {
    sed "s/^/[patch $repo] /" "$OUT/$repo/.patch.log" | tee -a "$LOG" >&2 || true
    die "patch failed: $patch_file"
  }

  printf '%s\n' "$patch_file" >> .applied-patches
}

verify_all_patches_applied(){
  local p missing=0

  [[ -d "$PATCH_DIR" ]] || return 0

  shopt -s nullglob
  for p in "$PATCH_DIR"/*.patch; do
    if ! grep -Fxq "$p" .applied-patches 2>/dev/null; then
      log "ERROR: patch file was not applied: $p"
      missing=1
    fi
  done
  shopt -u nullglob

  [[ "$missing" -eq 0 ]] || die "one or more patch files were not applied"
}

fetch_parse(){
  local repo="$1" branch
  mkdir -p "$OUT/$repo"

  for branch in master main rolling; do
    if curl -fsSL "$(raw_url "$repo" "$branch")" -o "$OUT/$repo/$repo.spec" 2>"$OUT/$repo/.curl-$branch.err"; then
      log "Fetched $repo ($branch)"
      apply_repo_patch "$repo"
      cat "$MACROS_FILE" "$OUT/$repo/$repo.spec" > "$OUT/$repo/.with-compat.spec"

      if ! rpmspec --parse "$OUT/$repo/.with-compat.spec" > "$OUT/$repo/.expanded.spec" 2>"$OUT/$repo/.parse.err"; then
        sed "s/^/[parse $repo] /" "$OUT/$repo/.parse.err" | tee -a "$LOG" >&2 || true
        die "rpmspec --parse failed: $repo"
      fi

      return
    fi
  done

  die "could not fetch root spec: $repo"
}

clean(){
  local x="$1" repo="${2:-}"
  [[ -n "$repo" ]] && x="${x//%\{name\}/$repo}"
  x="${x//%\{?_isa\}/}"
  x="${x//%\{EVRD\}/}"
  x="${x//%\{_lib\}/lib}"
  x="${x//%_lib/lib}"
  sed -E 's/#.*//;s/%\{[^}]+\}//g;s/[<>=].*//;s/^[[:space:]("'"'"']+//;s/[[:space:],)"'"'"']+$//' <<< "$x" | awk '{print $1}'
}

add_provider(){
  local p="$1" repo="$2" old
  [[ -n "$p" ]] || return 0
  old="$(awk -F '\t' -v p="$p" '$1==p{print $2; exit}' .providers.tsv)"
  [[ -z "$old" || "$old" == "$repo" ]] || die "ambiguous provider '$p': $old and $repo"
  [[ -n "$old" ]] || printf '%s\t%s\n' "$p" "$repo" >> .providers.tsv
}

index_repo(){
  local repo="$1"

  if ! rpmspec -q --qf '%{NAME}\n' "$OUT/$repo/.with-compat.spec" > "$OUT/$repo/.names" 2>"$OUT/$repo/.query.err"; then
    sed "s/^/[query $repo] /" "$OUT/$repo/.query.err" | tee -a "$LOG" >&2 || true
    die "rpmspec -q failed: $repo"
  fi

  while read -r p; do add_provider "$p" "$repo"; done < "$OUT/$repo/.names"

  awk 'BEGIN{IGNORECASE=1}/^[[:space:]]*Provides[[:space:]]*:/{sub(/^[^:]*:[[:space:]]*/,"");print}' "$OUT/$repo/.expanded.spec" |
  while read -r line; do clean "$line" "$repo"; done |
  while read -r p; do add_provider "$p" "$repo"; done
}

deps(){
  local repo="$1" line word
  awk 'BEGIN{IGNORECASE=1}/^[[:space:]]*(Requires|BuildRequires)[[:space:]]*:/{sub(/^[^:]*:[[:space:]]*/,"");print}' "$OUT/$repo/.expanded.spec" |
  while read -r line; do
    line="${line#\(}"; line="${line%\)}"
    line="${line%% if *}"; line="${line%% or *}"; line="${line%% and *}"
    if [[ "$line" =~ [[:space:]](>=|<=|=|>|<)[[:space:]] ]]; then
      clean "$line" "$repo"
    else
      for word in $line; do clean "$word" "$repo"; done
    fi
  done
}

build_deps(){
  local repo="$1" line word
  awk 'BEGIN{IGNORECASE=1}/^[[:space:]]*BuildRequires[[:space:]]*:/{sub(/^[^:]*:[[:space:]]*/,"");print}' "$OUT/$repo/.expanded.spec" |
  while read -r line; do
    line="${line#\(}"; line="${line%\)}"
    line="${line%% if *}"; line="${line%% or *}"; line="${line%% and *}"
    if [[ "$line" =~ [[:space:]](>=|<=|=|>|<)[[:space:]] ]]; then
      clean "$line" "$repo"
    else
      for word in $line; do clean "$word" "$repo"; done
    fi
  done
}

provider(){
  awk -F '\t' -v p="$1" '$1==p{print $2; exit}' .providers.tsv
}

download_index_all(){
  local repo
  log "Downloading and indexing all relevant specs"

  while read -r repo; do
    fetch_parse "$repo"
    index_repo "$repo"
  done < "$OUT/.all-repos"

  sort -u .providers.tsv -o .providers.tsv
  cp .providers.tsv "$OUT/.providers.tsv"
  log "Providers indexed: $(wc -l < .providers.tsv)"
}

walk(){
  local q repo dep prov
  q="$(mktemp)"
  echo "$ROOT" > "$q"

  log "Resolving dependency closure from $ROOT"

  while [[ -s "$q" ]]; do
    repo="$(head -n1 "$q")"
    sed -i '1d' "$q"
    grep -Fxq "$repo" .processed 2>/dev/null && continue
    [[ -f "$OUT/$repo/.expanded.spec" ]] || die "repo not indexed: $repo"

    log "Processing repo: $repo"
    echo "$repo" >> .processed

    while read -r dep; do
      [[ -n "$dep" ]] || continue
      wanted "$dep" || continue

      prov="$(provider "$dep")"
      [[ -n "$prov" ]] || die "no provider for dependency '$dep' while processing repo '$repo'"

      if [[ "$repo" == "$ROOT" && "$prov" != "$ROOT" ]]; then
        grep -Fxq "$prov" "$OUT/.task-sonicde.requires" 2>/dev/null || echo "$prov" >> "$OUT/.task-sonicde.requires"
      fi

      if wanted "$prov" && ! grep -Fxq "$prov" .processed "$q" 2>/dev/null; then
        log "$repo needs $dep -> $prov"
        echo "$prov" >> "$q"
      fi
    done < <(deps "$repo")

    while read -r dep; do
      [[ -n "$dep" ]] || continue
      wanted "$dep" || continue

      prov="$(provider "$dep")"
      [[ -n "$prov" ]] || die "no provider for BuildRequires '$dep' while processing repo '$repo'"

      [[ "$prov" != "$repo" ]] && printf '%s\t%s\n' "$prov" "$repo" >> .deps
    done < <(build_deps "$repo")
  done

  rm -f "$q"
}

write_task(){
  local spec="$OUT/$ROOT/$ROOT.spec"
  sort -u "$OUT/.task-sonicde.requires" -o "$OUT/.task-sonicde.requires"

  {
    cat <<'EOF'
Name:           task-sonicde
Version:        1
Release:        1%{?dist}
Summary:        SonicDE desktop environment metapackage
License:        MIT
BuildArch:      noarch

EOF
    while read -r p; do [[ -n "$p" ]] && printf 'Requires:       %s\n' "$p"; done < "$OUT/.task-sonicde.requires"
    cat <<'EOF'

%description
Metapackage that installs the SonicDE and Silver packages selected from the
OpenMandriva task-sonicde dependency set.

%prep
%build
%install
%files
EOF
  } > "$spec"
}

toposort(){
  python3 - .processed .deps > "$OUT/.order" <<'PY'
import sys
from collections import defaultdict
nodes = [x.strip() for x in open(sys.argv[1]) if x.strip()]
node_set, deps = set(nodes), defaultdict(set)

for line in open(sys.argv[2]):
    if not line.strip():
        continue
    dep, pkg = line.rstrip("\n").split("\t", 1)
    if dep in node_set and pkg in node_set and dep != pkg:
        deps[pkg].add(dep)

done, visiting, out = set(), set(), []

def visit(n):
    if n in done:
        return
    if n in visiting:
        raise SystemExit(f"dependency cycle involving {n}")
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

commit_and_queue(){
  mkdir -p "$OUT/$COMPAT"
  cp "specs/$COMPAT.spec" "$OUT/$COMPAT/$COMPAT.spec"

  cp .processed "$OUT/.processed"
  cp .deps "$OUT/.deps"
  cp .applied-patches "$OUT/.applied-patches"

  log "Final build order: $(wc -l < "$OUT/.order") packages"
  sed 's/^/  /' "$OUT/.order" | tee -a "$LOG" >&2

  rm -f .repos.tsv .providers.tsv .processed .deps .applied-patches

  (cd "$OUT"; git init -q; git add .; git -c user.name=builder -c user.email=builder@example.invalid commit --allow-empty -qm specs)

  url="file://$PWD/$OUT"
  commit="$(git -C "$OUT" rev-parse HEAD)"

  log "Queue first: $COMPAT"
  rpm-build-queue add --package "$COMPAT" --clone-url "$url" --commit "$commit" --subdir "$COMPAT" --spec "$COMPAT.spec"

  while read -r repo; do
    log "Queue: $repo"
    rpm-build-queue add --package "$repo" --clone-url "$url" --commit "$commit" --subdir "$repo" --spec "$repo.spec"
  done < "$OUT/.order"
}

need
github_repos
download_index_all
verify_all_patches_applied
walk
write_task
toposort
commit_and_queue
