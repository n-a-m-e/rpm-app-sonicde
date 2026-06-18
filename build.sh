#!/usr/bin/env bash
set -euo pipefail

OUT=${OUT:-sonicde-specs}
LOG=${LOG:-build-discovery.log}
ORG=${ORG:-OpenMandrivaAssociation}
TERMS=(sonic silver)
BRANCHES=(master main rolling)
BLACKLIST=(sonic sonic-visualiser python-silvercity rust-silver)

log(){ printf '[%s] %s\n' "$(date -u +'%H:%M:%S')" "$*" | tee -a "$LOG" >&2; }
die(){ log "ERROR: $*"; exit 1; }
norm(){ tr '[:upper:]' '[:lower:]' <<<"$1" | sed -E 's/[^a-z0-9]//g'; }
blacklisted(){ local x="${1,,}" b; for b in "${BLACKLIST[@]}"; do [[ "$x" == "${b,,}" ]] && return 0; done; return 1; }
need(){ local c; for c in curl tar git package-build-queue; do command -v "$c" >/dev/null || die "$c missing"; done; compgen -G 'specs/*.spec' >/dev/null || die 'no local spec files found in specs/'; }
add(){ local p="$1"; [[ -n "$p" ]] || return 0; blacklisted "$p" && { log "Skip blacklisted package: $p"; return 0; }; grep -Fxq "$p" "$OUT/.packages" 2>/dev/null || printf '%s\n' "$p" >> "$OUT/.packages"; }

init(){ rm -rf "$OUT" .repos.tsv "$LOG"; mkdir -p "$OUT"; : >"$OUT/.packages"; : >"$LOG"; }

copy_specs(){
  local spec pkg n=0
  log 'Copying local specs'
  while IFS= read -r spec; do
    pkg=${spec##*/}; pkg=${pkg%.spec}
    blacklisted "$pkg" && { log "Skip blacklisted local spec: $pkg"; continue; }
    mkdir -p "$OUT/$pkg"
    cp "$spec" "$OUT/$pkg/$pkg.spec"
    add "$pkg"
    n=$((n + 1))
  done < <(find specs -maxdepth 1 -type f -name '*.spec' | LC_ALL=C sort)
  log "Local specs declared: $n"
}

discover(){
  local term tmp full repo key n=0
  declare -A seen=()
  log 'GitHub lookup'
  : > .repos.tsv

  for term in "${TERMS[@]}"; do
    tmp=$(mktemp)
    if ! curl -fsSL --retry 3 --retry-delay 2 \
      -H 'Accept: application/vnd.github+json' -H 'User-Agent: sonicde-build-queue' \
      "https://api.github.com/search/repositories?q=${term}%20in:name,description+org:${ORG}&per_page=100" -o "$tmp"; then
      rm -f "$tmp"
      die "GitHub lookup failed: $term"
    fi

    while IFS= read -r full; do
      repo=${full##*/}; key=$(norm "$repo")
      [[ -n "$repo" && -n "$key" && -z "${seen[$key]:-}" ]] || continue
      seen[$key]=1
      blacklisted "$repo" && { log "Skip blacklisted GitHub repo: $repo"; continue; }
      printf '%s\t%s\n' "$repo" "$full" >> .repos.tsv
      n=$((n + 1))
    done < <(grep -aoE '"full_name"[[:space:]]*:[[:space:]]*"[^"/]+/[^"/]+"' "$tmp" | sed -E 's/.*"([^"]+\/[^"]+)"/\1/' || true)
    rm -f "$tmp"
  done

  [[ -s .repos.tsv ]] || die 'GitHub lookup returned no package repos'
  cut -f1 .repos.tsv | sort -u > "$OUT/.discovered-repos"
  awk -F '\t' 'BEGIN{OFS="\t"} {print $1, "https://github.com/" $2}' .repos.tsv > "$OUT/.repo-map.tsv"
  log "Discovered package repos: $n"
}

fetch(){
  local repo="$1" full="$2" b tmp archive
  tmp=$(mktemp -d)

  for b in "${BRANCHES[@]}"; do
    rm -rf "$OUT/$repo" "$tmp/repo.tar.gz"
    mkdir -p "$OUT/$repo"
    archive="https://codeload.github.com/$full/tar.gz/$b"

    if curl -fsSL --retry 3 --retry-delay 2 "$archive" -o "$tmp/repo.tar.gz" 2>"$tmp/curl-$b.err" && \
       tar -xzf "$tmp/repo.tar.gz" -C "$OUT/$repo" --strip-components=1 2>"$tmp/tar-$b.err" && \
       [[ -f "$OUT/$repo/$repo.spec" ]]; then
      log "Fetched package repo: $repo ($b)"
      rm -rf "$tmp"
      add "$repo"
      return 0
    fi
  done

  rm -rf "$tmp" "$OUT/$repo"
  die "could not fetch package repo with root spec: $repo"
}

fetch_all(){
  local repo full
  log 'Fetching discovered package repos'
  while IFS=$'\t' read -r repo full; do
    [[ -n "$repo" ]] || continue
    [[ ! -d "$OUT/$repo" ]] || die "discovered repo conflicts with existing package directory: $repo"
    fetch "$repo" "$full"
  done < .repos.tsv
}

queue(){
  local pkg url ref
  sort -u "$OUT/.packages" -o "$OUT/.packages"
  log "Final package declarations: $(wc -l < "$OUT/.packages") packages"
  sed 's/^/  /' "$OUT/.packages" | tee -a "$LOG" >&2

  git -C "$OUT" init -q
  git -C "$OUT" add .
  git -C "$OUT" -c user.name=builder -c user.email=builder@example.invalid commit --allow-empty -qm specs

  url="file://$PWD/$OUT"
  ref=$(git -C "$OUT" rev-parse HEAD)
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] || continue
    log "Declare package: $pkg"
    package-build-queue add --package "$pkg" --clone-url "$url" --ref "$ref" --subdir "$pkg" --spec "$pkg.spec"
  done < "$OUT/.packages"
}

main(){ need; init; copy_specs; discover; fetch_all; queue; }
main "$@"
