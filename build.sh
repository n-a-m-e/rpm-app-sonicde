#!/usr/bin/env bash
set -euo pipefail

OUT=sonicde-specs
LOG="${LOG:-build-discovery.log}"

SEARCHES=(
  'https://api.github.com/search/repositories?q=sonic%20in:name,description+org:OpenMandrivaAssociation&per_page=100'
  'https://api.github.com/search/repositories?q=silver%20in:name,description+org:OpenMandrivaAssociation&per_page=100'
)

DISCOVERY_BLACKLIST=(
  sonic
  sonic-visualiser
  python-silvercity
  rust-silver
)

rm -rf "$OUT" .repos.tsv "$LOG"
mkdir -p "$OUT"
: > "$OUT/.packages"
: > "$LOG"

log(){ printf '[%s] %s\n' "$(date -u +'%H:%M:%S')" "$*" | tee -a "$LOG" >&2; }
die(){ log "ERROR: $*"; exit 1; }
key(){ tr '[:upper:]' '[:lower:]' <<< "$1" | sed -E 's/[^a-z0-9]//g'; }

need(){
  command -v curl >/dev/null || die "curl missing"
  command -v python3 >/dev/null || die "python3 missing"
  command -v tar >/dev/null || die "tar missing"
  command -v git >/dev/null || die "git missing"
  command -v package-build-queue >/dev/null || die "package-build-queue missing"
  compgen -G "specs/*.spec" >/dev/null || die "no local spec files found in specs/"
}

local_spec_names(){
  find specs -maxdepth 1 -type f -name '*.spec' -printf '%f\n' |
  sed 's/\.spec$//' |
  LC_ALL=C sort
}

record_package(){
  local name="$1"
  [[ -n "$name" ]] || return 0
  if ! grep -Fxq "$name" "$OUT/.packages" 2>/dev/null; then
    printf '%s\n' "$name" >> "$OUT/.packages"
  fi
}

copy_local_specs(){
  local name src dst

  log "Copying local specs"

  while read -r name; do
    [[ -n "$name" ]] || continue
    src="specs/$name.spec"
    dst="$OUT/$name/$name.spec"

    mkdir -p "$OUT/$name"
    cp "$src" "$dst"
    record_package "$name"
  done < <(local_spec_names)

  log "Local specs declared: $(local_spec_names | wc -l)"
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

BLACKLIST = {"sonic", "python-silvercity", "rust-silver"}

def keep_repo(name):
    return name.lower() not in BLACKLIST

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
  [[ -s .repos.tsv ]] || die "GitHub lookup returned no package repos"

  awk -F '\t' '{print $2}' .repos.tsv | LC_ALL=C sort -u > "$OUT/.discovered-repos"
  cp .repos.tsv "$OUT/.repo-map.tsv"

  log "Discovered package repos: $(wc -l < "$OUT/.discovered-repos")"
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

fetch_repo(){
  local repo="$1" branch tmp
  tmp="$(mktemp -d)"

  for branch in master main rolling; do
    rm -rf "$OUT/$repo" "$tmp/repo.tar.gz"
    mkdir -p "$OUT/$repo"

    if curl -fsSL "$(archive_url "$repo" "$branch")" -o "$tmp/repo.tar.gz" 2>"$OUT/$repo/.curl-$branch.err"; then
      if tar -xzf "$tmp/repo.tar.gz" -C "$OUT/$repo" --strip-components=1 2>"$OUT/$repo/.tar-$branch.err"; then
        if [[ -f "$OUT/$repo/$repo.spec" ]]; then
          log "Fetched package repo: $repo ($branch)"
          rm -rf "$tmp"
          record_package "$repo"
          return 0
        fi
      fi
    fi
  done

  rm -rf "$tmp" "$OUT/$repo"
  die "could not fetch package repo with root spec: $repo"
}

fetch_discovered_repos(){
  local repo

  log "Fetching discovered package repos"

  while read -r repo; do
    [[ -n "$repo" ]] || continue
    if [[ -d "$OUT/$repo" ]]; then
      die "discovered repo conflicts with existing package directory: $repo"
    fi
    fetch_repo "$repo"
  done < "$OUT/.discovered-repos"
}

commit_and_declare(){
  local url ref repo

  sort -u "$OUT/.packages" -o "$OUT/.packages"

  log "Final package declarations: $(wc -l < "$OUT/.packages") packages"
  sed 's/^/  /' "$OUT/.packages" | tee -a "$LOG" >&2

  rm -f .repos.tsv

  (cd "$OUT"; git init -q; git add .; git -c user.name=builder -c user.email=builder@example.invalid commit --allow-empty -qm specs)

  url="file://$PWD/$OUT"
  ref="$(git -C "$OUT" rev-parse HEAD)"

  while read -r repo; do
    [[ -n "$repo" ]] || continue
    log "Declare package: $repo"
    package-build-queue add \
      --package "$repo" \
      --clone-url "$url" \
      --ref "$ref" \
      --subdir "$repo" \
      --spec "$repo.spec"
  done < "$OUT/.packages"
}

need
copy_local_specs
github_repos
fetch_discovered_repos
commit_and_declare
