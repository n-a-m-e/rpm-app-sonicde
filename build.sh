#!/usr/bin/env bash
set -euo pipefail

OUT=sonicde-specs
ORG=OpenMandrivaAssociation
MATCH='sonic|silver'

rm -rf "$OUT" .q .seen
mkdir -p "$OUT"
echo task-sonicde > .q
: > .seen
: > "$OUT/.order"

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
  [[ "$d" == task-sonicde-minimal ]] && { echo task-sonicde; return; }
  [[ "$d" == sonic-* ]] && { echo "$d"; return; }

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

while [[ -s .q ]]; do
  r="$(head -n1 .q)"
  sed -i '1d' .q

  grep -Fxq "$r" .seen 2>/dev/null && continue
  echo "$r" >> .seen

  fetch "$r" || continue
  deps "$r" | while read -r d; do
    [[ "$r" == task-sonicde ]] && ! grep -Eiq "$MATCH" <<< "$d" && continue
    add "$d"
  done
done

rm -f .q .seen

(cd "$OUT"; git init -q; git add .; git -c user.name=builder -c user.email=builder@example.invalid commit --allow-empty -qm specs)

url="file://$PWD/$OUT"
commit="$(git -C "$OUT" rev-parse HEAD)"

tac "$OUT/.order" | while read -r p; do
  rpm-build-queue add --package "$p" --clone-url "$url" --commit "$commit" --subdir "$p" --spec "$p.spec"
done
