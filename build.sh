#!/usr/bin/env bash
set -euo pipefail

OUT=sonicde-specs
ROOT=task-sonicde
COMPAT=openmandriva-buildrequires-compat
MACROS_FILE="${MACROS_FILE:-macros/openmandriva-compat.macros}"
PATCH_DIR="${PATCH_DIR:-patches}"
INDEX_PATCH_ROOT="$OUT/.index-patched"
LOG="${LOG:-build-discovery.log}"

SEARCHES=(
  'https://api.github.com/search/repositories?q=sonic%20in:name,description+org:OpenMandrivaAssociation&per_page=100'
  'https://api.github.com/search/repositories?q=silver%20in:name,description+org:OpenMandrivaAssociation&per_page=100'
)

rm -rf "$OUT" .repos.tsv .providers.tsv .processed .deps .builddeps .runtimedeps .applied-patches "$LOG"
mkdir -p "$OUT"
: > .providers.tsv
: > .processed
: > .deps
: > .builddeps
: > .runtimedeps
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
  command -v tar >/dev/null || die "tar missing"
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

archive_url(){
  local repo="$1" branch="$2" u name
  u="$(repo_url "$repo")"
  [[ "$u" =~ ^https://github.com/([^/]+)/([^/]+)$ ]] || die "bad/missing GitHub URL for $repo"
  name="${BASH_REMATCH[2]}"
  printf 'https://codeload.github.com/%s/%s/tar.gz/%s\n' "${BASH_REMATCH[1]}" "$name" "$branch"
}

prepare_index_spec(){
  local repo="$1" patch_file="$PATCH_DIR/$repo.spec.patch" index_repo="$INDEX_PATCH_ROOT/$repo"

  rm -rf "$index_repo"
  mkdir -p "$INDEX_PATCH_ROOT"
  cp -a "$OUT/$repo" "$index_repo"

  if [[ -f "$patch_file" ]]; then
    log "Applying patch for index only: $patch_file"
    patch -d "$INDEX_PATCH_ROOT" --batch --forward -p1 < "$patch_file" > "$OUT/$repo/.index-patch.log" 2>&1 || {
      sed "s/^/[index patch $repo] /" "$OUT/$repo/.index-patch.log" | tee -a "$LOG" >&2 || true
      die "index patch failed: $patch_file"
    }
    printf '%s\n' "$patch_file" >> .applied-patches
  fi

  cat "$MACROS_FILE" "$index_repo/$repo.spec" > "$OUT/$repo/.with-compat.spec"
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
  local repo="$1" branch tmp
  tmp="$(mktemp -d)"

  for branch in master main rolling; do
    rm -rf "$OUT/$repo" "$tmp/repo.tar.gz"
    mkdir -p "$OUT/$repo"

    if curl -fsSL "$(archive_url "$repo" "$branch")" -o "$tmp/repo.tar.gz" 2>"$OUT/$repo/.curl-$branch.err"; then
      if tar -xzf "$tmp/repo.tar.gz" -C "$OUT/$repo" --strip-components=1 2>"$OUT/$repo/.tar-$branch.err"; then
        if [[ -f "$OUT/$repo/$repo.spec" ]]; then
          log "Fetched full repo: $repo ($branch)"
          rm -rf "$tmp"

          prepare_index_spec "$repo"

          rpmspec --parse "$OUT/$repo/.with-compat.spec" > "$OUT/$repo/.expanded.spec" 2>"$OUT/$repo/.parse.err" || {
            sed "s/^/[parse $repo] /" "$OUT/$repo/.parse.err" | tee -a "$LOG" >&2 || true
            die "rpmspec --parse failed: $repo"
          }

          return
        fi
      fi
    fi
  done

  rm -rf "$tmp" "$OUT/$repo"
  die "could not fetch full repo with root spec: $repo"
}

rpm_name(){
  # rpmspec query output can still contain relation/version suffixes.
  # This strips only generic RPM dependency syntax; macro expansion is handled by rpmspec.
  local x="$1"
  sed -E '
    s/#.*//;
    s/[[:space:]]+(>=|<=|=|>|<).*$//;
    s/^[[:space:]("'"'"']+//;
    s/[[:space:],)"'"'"']+$//;
  ' <<< "$x" | awk '{print $1}'
}

query_spec(){
  local repo="$1" mode="$2"

  case "$mode" in
    names)         rpmspec -q --qf '%{NAME}\n' "$OUT/$repo/.with-compat.spec" ;;
    provides)      rpmspec -q --provides "$OUT/$repo/.with-compat.spec" ;;
    requires)      rpmspec -q --requires "$OUT/$repo/.with-compat.spec" ;;
    buildrequires) rpmspec -q --buildrequires "$OUT/$repo/.with-compat.spec" ;;
    *)             die "unknown query mode: $mode" ;;
  esac
}

query_names(){
  local repo="$1"
  local mode="$2"
  local out="$OUT/$repo/.query-$mode"

  if ! query_spec "$repo" "$mode" > "$out" 2>"$OUT/$repo/.query-$mode.err"; then
    sed "s/^/[rpmspec $mode $repo] /" "$OUT/$repo/.query-$mode.err" | tee -a "$LOG" >&2 || true
    die "rpmspec query failed: $mode for $repo"
  fi

  while read -r line; do
    rpm_name "$line"
  done < "$out" | awk 'NF'
}

add_provider(){
  local p="$1" repo="$2" old
  [[ -n "$p" ]] || return 0
  old="$(awk -F '\t' -v p="$p" '$1==p{print $2; exit}' .providers.tsv)"
  [[ -z "$old" || "$old" == "$repo" ]] || die "ambiguous provider '$p': $old and $repo"
  [[ -n "$old" ]] || printf '%s\t%s\n' "$p" "$repo" >> .providers.tsv
}

index_repo(){
  local repo="$1" p

  while read -r p; do
    add_provider "$p" "$repo"
  done < <(query_names "$repo" names)

  while read -r p; do
    add_provider "$p" "$repo"
  done < <(query_names "$repo" provides)
}

provider(){
  awk -F '\t' -v p="$1" '$1==p{print $2; exit}' .providers.tsv
}

download_index_all(){
  local repo
  log "Downloading full repos and indexing specs"

  while read -r repo; do
    fetch_parse "$repo"
    index_repo "$repo"
  done < "$OUT/.all-repos"

  sort -u .providers.tsv -o .providers.tsv
  cp .providers.tsv "$OUT/.providers.tsv"
  log "Providers indexed: $(wc -l < .providers.tsv)"
}

dep_items(){
  local repo="$1" kind dep

  while read -r dep; do
    printf 'BuildRequires\t%s\n' "$dep"
  done < <(query_names "$repo" buildrequires)

  while read -r dep; do
    printf 'Requires\t%s\n' "$dep"
  done < <(query_names "$repo" requires)
}

scan_repo_deps(){
  local repo="$1" kind dep prov

  while IFS=$'\t' read -r kind dep; do
    [[ -n "$dep" ]] || continue
    wanted "$dep" || continue

    prov="$(provider "$dep")"
    [[ -n "$prov" ]] || die "no provider for $kind '$dep' while processing repo '$repo'"

    if [[ "$repo" == "$ROOT" && "$prov" != "$ROOT" ]]; then
      grep -Fxq "$prov" "$OUT/.task-sonicde.requires" 2>/dev/null || echo "$prov" >> "$OUT/.task-sonicde.requires"
    fi

    if wanted "$prov" && ! grep -Fxq "$prov" .processed "$q" 2>/dev/null; then
      log "$repo needs $dep -> $prov"
      echo "$prov" >> "$q"
    fi

    [[ "$prov" == "$repo" ]] && continue

    printf '%s\t%s\n' "$prov" "$repo" >> .deps
    case "${kind,,}" in
      buildrequires) printf '%s\t%s\n' "$prov" "$repo" >> .builddeps ;;
      requires)      printf '%s\t%s\n' "$prov" "$repo" >> .runtimedeps ;;
    esac
  done < <(dep_items "$repo")
}

walk(){
  local q repo
  q="$(mktemp)"
  echo "$ROOT" > "$q"

  log "Resolving dependency closure from $ROOT"

  while [[ -s "$q" ]]; do
    repo="$(head -n1 "$q")"
    sed -i '1d' "$q"
    grep -Fxq "$repo" .processed 2>/dev/null && continue
    [[ -f "$OUT/$repo/.with-compat.spec" ]] || die "repo not indexed: $repo"

    log "Processing repo: $repo"
    echo "$repo" >> .processed
    scan_repo_deps "$repo"
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
  # Use all provider dependencies to keep runtime dependencies installable, but
  # do not let runtime dependency cycles destroy the useful BuildRequires order.
  #
  # Algorithm:
  # 1. Collapse SCCs using all edges (.deps = BuildRequires + Requires).
  # 2. Topologically order the SCCs.
  # 3. Inside each SCC, topologically order only BuildRequires edges.
  #    If BuildRequires itself has a cycle, keep the original order and warn.
  python3 - .processed .deps .builddeps > "$OUT/.order" <<'PY'
import sys
from collections import defaultdict, deque

nodes = [x.strip() for x in open(sys.argv[1]) if x.strip()]
node_set = set(nodes)

def read_edges(path):
    g = defaultdict(set)
    for line in open(path):
        if not line.strip():
            continue
        dep, pkg = line.rstrip("\n").split("\t", 1)
        if dep in node_set and pkg in node_set and dep != pkg:
            g[pkg].add(dep)
    return g

all_graph = read_edges(sys.argv[2])
build_graph = read_edges(sys.argv[3])

index = 0
stack, on_stack = [], set()
idx, low = {}, {}
components = []

def strongconnect(v):
    global index
    idx[v] = index
    low[v] = index
    index += 1
    stack.append(v)
    on_stack.add(v)

    for w in all_graph[v]:
        if w not in idx:
            strongconnect(w)
            low[v] = min(low[v], low[w])
        elif w in on_stack:
            low[v] = min(low[v], idx[w])

    if low[v] == idx[v]:
        comp = []
        while True:
            w = stack.pop()
            on_stack.remove(w)
            comp.append(w)
            if w == v:
                break
        components.append(comp)

for n in nodes:
    if n not in idx:
        strongconnect(n)

comp_id = {}
for i, comp in enumerate(components):
    for n in comp:
        comp_id[n] = i

comp_deps = defaultdict(set)
for pkg, deps in all_graph.items():
    for dep in deps:
        a, b = comp_id[pkg], comp_id[dep]
        if a != b:
            comp_deps[a].add(b)

done, comp_order = set(), []

def visit_comp(c):
    if c in done:
        return
    for d in sorted(comp_deps[c]):
        visit_comp(d)
    done.add(c)
    comp_order.append(c)

for n in nodes:
    visit_comp(comp_id[n])

def order_inside_component(comp):
    comp_set = set(comp)
    stable = [n for n in nodes if n in comp_set]

    indeg = {n: 0 for n in stable}
    children = defaultdict(list)

    for pkg in stable:
        for dep in build_graph[pkg]:
            if dep in comp_set:
                children[dep].append(pkg)
                indeg[pkg] += 1

    q = deque([n for n in stable if indeg[n] == 0])
    out = []

    while q:
        n = q.popleft()
        out.append(n)
        for child in sorted(children[n], key=lambda x: stable.index(x)):
            indeg[child] -= 1
            if indeg[child] == 0:
                q.append(child)

    if len(out) != len(stable):
        print(
            "BuildRequires cycle inside runtime group; preserving discovery order for: "
            + ", ".join(stable),
            file=sys.stderr,
        )
        return stable

    return out

seen = set()
for c in comp_order:
    comp = [n for n in nodes if comp_id[n] == c]
    ordered = order_inside_component(comp)
    if len(comp) > 1:
        print(
            "runtime dependency cycle group ordered by BuildRequires: "
            + ", ".join(ordered),
            file=sys.stderr,
        )
    for n in ordered:
        if n not in seen:
            seen.add(n)
            print(n)
PY
}

commit_and_queue(){
  mkdir -p "$OUT/$COMPAT"
  cp "specs/$COMPAT.spec" "$OUT/$COMPAT/$COMPAT.spec"

  cp .processed "$OUT/.processed"
  cp .deps "$OUT/.deps"
  cp .builddeps "$OUT/.builddeps"
  cp .runtimedeps "$OUT/.runtimedeps"
  cp .applied-patches "$OUT/.applied-patches"

  log "Final build order: $(wc -l < "$OUT/.order") packages"
  sed 's/^/  /' "$OUT/.order" | tee -a "$LOG" >&2

  rm -f .repos.tsv .providers.tsv .processed .deps .builddeps .runtimedeps .applied-patches

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
sort -u .deps -o .deps
sort -u .builddeps -o .builddeps
sort -u .runtimedeps -o .runtimedeps
toposort
commit_and_queue
