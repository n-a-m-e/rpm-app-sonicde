#!/usr/bin/env bash
set -euo pipefail

ORG=OpenMandrivaAssociation
OUT=sonicde-specs
MATCH='sonic|silver'

rm -rf "$OUT" .q .s
mkdir -p "$OUT"
: > .q; : > .s; : > "$OUT/.order"; : > "$OUT/.provides"

fetch() {
  mkdir -p "$OUT/$1"
  for b in master main rolling; do
    curl -fsSL "https://raw.githubusercontent.com/$ORG/$1/$b/$1.spec" -o "$OUT/$1/$1.spec" 2>/dev/null && return
  done
  rm -rf "$OUT/$1"; return 1
}

clean() {
  x="${1//%\{name\}/$2}"; x="${x//%\{?_isa\}/}"; x="${x//%\{EVRD\}/}"; x="${x//%\{_lib\}/lib}"
  sed -E 's/#.*//;s/%\{[^}]+\}//g;s/[<>=].*//;s/^[[:space:]("'\'']+//;s/[[:space:],)"'\'']+$//' <<< "$x" | awk '{print $1}'
}

idx() {
  r="$1"; s="$OUT/$r/$r.spec"
  echo -e "$r\t$r" >> "$OUT/.provides"
  awk -v r="$r" '
    /^[[:space:]]*%package[[:space:]]+-n[[:space:]]+/ {print r "\t" $3}
    /^[[:space:]]*%package[[:space:]]+[^-[:space:]]+/ {print r "\t" r "-" $2}
    /^[[:space:]]*Provides[[:space:]]*:/ {
      sub(/^[^:]*:[[:space:]]*/,""); gsub(/%[{][?]_isa[}]/,""); gsub(/%[{]name[}]/,r)
      gsub(/%[{][^}]+[}]/,""); sub(/[[:space:]]*(>=|<=|=|>|<)[[:space:]].*/,"")
      gsub(/^[[:space:]]+|[[:space:]]+$/,""); if ($0) print r "\t" $0
    }' "$s" >> "$OUT/.provides"
}

repo() { awk -F '\t' -v d="$1" '$2==d{print $1;exit}' "$OUT/.provides"; }

deps() {
  r="$1"; s="$OUT/$r/$r.spec"
  awk 'BEGIN{IGNORECASE=1}/^[[:space:]]*(Requires|BuildRequires|Recommends|Suggests)[[:space:]]*:/{sub(/^[^:]*:[[:space:]]*/,"");print}' "$s" |
  while read -r l; do
    [[ "$l" =~ ^%mklibname[[:space:]]+-d[[:space:]]+([^[:space:]]+) ]] && { echo "${BASH_REMATCH[1]}"; continue; }
    l="${l#\(}"; l="${l%\)}"; l="${l%% if *}"; l="${l%% or *}"; l="${l%% and *}"
    [[ "$l" =~ [[:space:]](>=|<=|=|>|<)[[:space:]] ]] && echo "$(clean "$l" "$r")" || for w in $l; do echo "$(clean "$w" "$r")"; done
  done
}

add() {
  d="$1"; [[ -n "$d" ]] || return 0
  grep -Eiq "$MATCH" <<< "$d" || return 0
  r="$(repo "$d")"; r="${r:-$d}"
  grep -Eiq "$MATCH" <<< "$r" || return 0
  grep -Fxq "$r" .s .q 2>/dev/null || echo "$r" >> .q
}

page=1
while :; do
  json="$(curl -fsSL "https://api.github.com/orgs/$ORG/repos?per_page=100&page=$page")"
  grep -q '"name":' <<< "$json" || break
  grep -o '"name": *"[^"]*"' <<< "$json" | sed -E 's/.*"([^"]+)".*/\1/' | grep -Ei "$MATCH" |
  while read -r r; do fetch "$r" && idx "$r"; done
  page=$((page+1))
done
fetch task-sonicde; idx task-sonicde
sort -u -o "$OUT/.provides" "$OUT/.provides"

add task-sonicde
while [[ -s .q ]]; do
  r="$(head -n1 .q)"; sed -i '1d' .q
  grep -Fxq "$r" .s 2>/dev/null && continue
  echo "$r" >> .s; echo "$r" >> "$OUT/.order"
  deps "$r" | while read -r d; do [[ "$r" == task-sonicde ]] && ! grep -Eiq "$MATCH" <<< "$d" || add "$d"; done
done
rm -f .q .s

(cd "$OUT"; git init -q; git add .; git -c user.name=builder -c user.email=builder@example.invalid commit --allow-empty -qm specs)

url="file://$PWD/$OUT"; commit="$(git -C "$OUT" rev-parse HEAD)"
tac "$OUT/.order" | while read -r p; do
  rpm-build-queue add --package "$p" --clone-url "$url" --commit "$commit" --subdir "$p" --spec "$p.spec"
done
