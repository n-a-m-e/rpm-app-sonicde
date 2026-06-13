#!/usr/bin/env bash
set -euo pipefail

OUT=sonicde-specs
ROOT=task-sonicde
MATCH='sonic|silver'

rm -rf "$OUT" .queue .seen .tmp
mkdir -p "$OUT"
echo "$ROOT" > .queue
: > .seen
: > "$OUT/.order"

fetch_spec() {
  local p="$1" b dir="$OUT/$p"
  mkdir -p "$dir"

  for b in master main rolling; do
    curl -fsSL "https://raw.githubusercontent.com/OpenMandrivaAssociation/$p/$b/$p.spec" \
      -o "$dir/$p.spec" 2>/dev/null && {
        echo "$p" >> "$OUT/.order"
        return 0
      }
  done

  rm -rf "$dir"
  return 1
}

clean_dep() {
  local x="${1//%\{name\}/$2}"
  x="${x//%\{?_isa\}/}"
  sed -E 's/#.*//;s/[<>=].*//;s/^[[:space:]("'\'']+//;s/[[:space:],)"'\'']+$//' <<< "$x" |
    awk '{print $1}'
}

enqueue() {
  local d="$1"

  [[ -n "$d" ]] || return 0
  grep -Eiq "$MATCH" <<< "$d" || return 0
  grep -Fxq "$d" .seen .queue 2>/dev/null && return 0

  echo "$d" >> .queue
}

scan_spec() {
  local pkg="$1" spec="$2" line word dep

  while read -r line; do
    [[ "$line" =~ ^%mklibname[[:space:]]+-d[[:space:]]+([^[:space:]]+) ]] && {
      enqueue "${BASH_REMATCH[1]}"
      continue
    }

    for word in $line; do
      dep="$(clean_dep "$word" "$pkg")"
      [[ "$dep" == "$pkg" ]] && continue
      enqueue "$dep"
    done
  done < <(
    awk 'BEGIN{IGNORECASE=1}/^[[:space:]]*(Requires|BuildRequires|Recommends|Suggests)[[:space:]]*:/{sub(/^[^:]*:[[:space:]]*/,"");print}' "$spec"
  )
}

while [[ -s .queue ]]; do
  p="$(head -n1 .queue)"
  tail -n +2 .queue > .tmp || true
  mv .tmp .queue

  grep -Fxq "$p" .seen 2>/dev/null && continue
  echo "$p" >> .seen

  fetch_spec "$p" || continue
  scan_spec "$p" "$OUT/$p/$p.spec"
done

rm -f .queue .seen .tmp

(
  cd "$OUT"
  git init -q
  git add .
  git -c user.name=builder -c user.email=builder@example.invalid commit --allow-empty -qm "download sonicde specs"
)

clone_url="file://$PWD/$OUT"
commit="$(git -C "$OUT" rev-parse HEAD)"

tac "$OUT/.order" | while read -r pkg; do
  rpm-build-queue add \
    --package "$pkg" \
    --clone-url "$clone_url" \
    --commit "$commit" \
    --subdir "$pkg" \
    --spec "$pkg.spec"
done
