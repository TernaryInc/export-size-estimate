#!/usr/bin/env bash
# Estimate ongoing storage of an Azure Cost Management export in Blob Storage.
#
# Lists blobs whose lastModified falls on one UTC day (default: last day of last
# month), sums their sizes, and downloads the manifest.json file(s), which
# describe the export (timeFrame, type, granularity, overwrite behaviour, run
# start/end dates, byteCount), so you can tell whether a day's drop is a full
# month-to-date dump or just one day.
#
# Auth: whatever `az` already has (az login). Tries --auth-mode login (needs Storage
# Blob Data Reader), then falls back to key; AZ_AUTH_MODE=login|key pins one. Or set
# AZURE_STORAGE_KEY / AZURE_STORAGE_SAS_TOKEN / AZURE_STORAGE_CONNECTION_STRING.
# Needs: az CLI, awk. Optional: jq.
#
# Usage: azure_export_size.sh URL [-d YYYY-MM-DD] [-o OUTDIR] [--scope ...]
#        azure_export_size.sh ACCOUNT CONTAINER [PREFIX] [-d YYYY-MM-DD] [-o OUTDIR] [--scope ...]
#   URL is any blob URL copied from the Azure Storage browser, e.g. the one for a
#   manifest.json or part_0_0001.csv inside an export run:
#   https://ACCOUNT.blob.core.windows.net/CONTAINER/actuals/my-export/20260901-20260930/202609211557/GUID/part_0_0001.csv
#   ACCOUNT, CONTAINER and the export root (the folder above the YYYYMMDD-YYYYMMDD
#   period folders, here actuals/my-export/) are derived from it. Any ?SAS query is ignored.
#                              [--scope /subscriptions/ID | /providers/Microsoft.Billing/billingAccounts/ID]
#   --scope additionally dumps export definitions via `az costmanagement export list`
#   (needs: az extension add --name costmanagement).
set -euo pipefail

usage() { sed -n '2,/^set -e/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }

POS=(); DAY=""; OUT=""; SCOPE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d) DAY="$2"; shift 2 ;;
    -o) OUT="$2"; shift 2 ;;
    --scope) SCOPE="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    -*) echo "unknown arg: $1" >&2; usage ;;
    *) POS+=("$1"); shift ;;
  esac
done
[[ ${#POS[@]} -ge 1 ]] || usage
if [[ "${POS[0]}" =~ ^https?:// ]]; then
  url="${POS[0]%%[?#]*}"; url="${url#*://}"
  host="${url%%/*}"; path="${url#*/}"
  ACCOUNT="${host%%.*}"; CONTAINER="${path%%/*}"
  [[ "$path" == */* ]] && path="${path#*/}" || path=""
  # percent-decode (%20 etc.)
  path=$(printf '%b' "${path//%/\\x}")
  # export root = everything above the first YYYYMMDD-YYYYMMDD period folder
  PREFIX=""; found=0; IFS='/' read -r -a parts <<< "$path"
  for p in "${parts[@]}"; do
    if [[ "$p" =~ ^[0-9]{8}-[0-9]{8}$ ]]; then found=1; break; fi
    PREFIX+="$p/"
  done
  if [[ $found -eq 0 ]]; then
    echo "warning: no YYYYMMDD-YYYYMMDD period folder in URL path; using its parent folder as the export root" >&2
    PREFIX="${path%/*}/"; [[ "$path" == */* ]] || PREFIX=""
  fi
else
  [[ ${#POS[@]} -ge 2 ]] || usage
  ACCOUNT="${POS[0]}"; CONTAINER="${POS[1]}"; PREFIX="${POS[2]:-}"
  [[ -z "$PREFIX" || "$PREFIX" == */ ]] || PREFIX="$PREFIX/"
fi
# Auth modes to try in order; AZ_AUTH_MODE pins a single one.
if [[ -n "${AZ_AUTH_MODE:-}" ]]; then AUTH_MODES=("$AZ_AUTH_MODE"); else AUTH_MODES=(login key); fi
AUTH=""; FAILS=""

if [[ -z "$DAY" ]]; then
  if date -v1d >/dev/null 2>&1; then DAY=$(date -v1d -v-1d +%F)
  else DAY=$(date -d "$(date +%Y-%m-01) -1 day" +%F); fi
fi
[[ "$DAY" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "bad date: $DAY" >&2; exit 1; }

# --- preflight: check dependencies one by one, fail fast -------------------
need() { # need CMD HINT
  if command -v "$1" >/dev/null 2>&1; then true; else echo "MISSING $1: $2" >&2; exit 1; fi
}
need az   "install Azure CLI (brew install azure-cli)"
need awk  "required"
need sed  "required"
need tr   "required"
need sort "required"
need date "required"
if command -v jq >/dev/null 2>&1; then HAVE_JQ=1; else HAVE_JQ=0; fi
sub=$(az account show --query name -o tsv 2>&1) \
  || { echo "FAIL az login required: $sub" >&2; exit 1; }
for mode in "${AUTH_MODES[@]}"; do
  if probe=$(az storage blob list --account-name "$ACCOUNT" --container-name "$CONTAINER" --auth-mode "$mode" --num-results 1 --only-show-errors -o tsv 2>&1 >/dev/null); then
    AUTH="$mode"; break
  fi
  FAILS+="  --auth-mode $mode: $(echo "$probe" | sed 's/^ERROR: *//' | grep -m1 '[[:alnum:]]')"$'\n'
done
[[ -n "$AUTH" ]] || { echo "FAIL cannot list $ACCOUNT/$CONTAINER:" >&2; printf '%s' "$FAILS" >&2; exit 1; }

OUT="${OUT:-./azure-size-out/${ACCOUNT}-${CONTAINER}-${DAY}}"
mkdir -p "$OUT/manifests"
AZO=(--account-name "$ACCOUNT" --container-name "$CONTAINER" --auth-mode "$AUTH" --only-show-errors)
PFX=(); [[ -n "$PREFIX" ]] && PFX=(--prefix "$PREFIX")

echo "$ACCOUNT/$CONTAINER/$PREFIX day=$DAY auth=$AUTH out=$OUT"

# --- 1. blobs written on that day -----------------------------------------
az storage blob list "${AZO[@]}" "${PFX[@]}" --num-results '*' -o tsv \
  --query "[?starts_with(properties.lastModified, '${DAY}')].[name, properties.contentLength, properties.lastModified]" \
  > "$OUT/raw_list.txt"
awk -F'\t' 'NF>=3 && $2 ~ /^[0-9]+$/' "$OUT/raw_list.txt" > "$OUT/files.tsv"

if [[ ! -s "$OUT/files.tsv" ]]; then
  echo "no blobs modified on $DAY under '$PREFIX' (check prefix/date)." >&2
fi

awk -F'\t' '
  function human(b,  u,i){split("B KiB MiB GiB TiB",u," ");i=1;while(b>=1024&&i<5){b/=1024;i++}return sprintf("%.1f %s",b,u[i])}
  {
    kind = ($1 ~ /[Mm]anifest\.json$/) ? "manifest" : "data"
    per="-"; n=split($1,p,"/")
    for(i=1;i<=n;i++) if(p[i] ~ /^[0-9]+-[0-9]+$/ && length(p[i])==17) per=p[i]
    k=per SUBSEP kind; c[k]++; b[k]+=$2; tc[kind]++; tb[kind]+=$2
  }
  END{
    for(k in c){ split(k,a,SUBSEP); printf "%-18s %-8s %4d files  %10s\n", a[1],a[2],c[k],human(b[k]) | "sort" }
    close("sort")
  }' "$OUT/files.tsv"

DATA_BYTES=$(awk -F'\t' '$1 !~ /[Mm]anifest\.json$/ {s+=$2} END{print s+0}' "$OUT/files.tsv")
DIM=$((10#${DAY:8:2}))
awk -v b="$DATA_BYTES" -v d="$DIM" 'function human(b,  u,i){split("B KiB MiB GiB TiB",u," ");i=1;while(b>=1024&&i<5){b/=1024;i++}return sprintf("%.1f %s",b,u[i])} BEGIN{printf "day data %s; per month: ~%s if month-to-date dump, ~%s if daily-only\n", human(b), human(b), human(b*d)}'

# --- 2. manifests -----------------------------------------------------------
MAN_KEYS=$(awk -F'\t' '$1 ~ /[Mm]anifest\.json$/ {print $1}' "$OUT/files.tsv")
if [[ -z "$MAN_KEYS" ]]; then
  echo "no manifest modified on $DAY; using latest" >&2
  MAN_KEYS=$(az storage blob list "${AZO[@]}" "${PFX[@]}" --num-results '*' -o tsv \
    --query "sort_by([?ends_with(name, 'anifest.json')], &properties.lastModified)[-1].name" 2>/dev/null | grep -v '^None$' || true)
fi
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  dest="$OUT/manifests/$(echo "$name" | tr '/' '_')"
  az storage blob download "${AZO[@]}" --name "$name" --file "$dest" --no-progress --overwrite true >/dev/null
  echo "manifest: $name"
  if [[ $HAVE_JQ -eq 1 ]]; then
    jq -c '{export: .exportConfig, delivery: .deliveryConfig, run: .runInfo, byteCount, blobCount, dataRowCount}' "$dest" 2>/dev/null \
      || jq -c 'with_entries(select(.value|type!="array"))' "$dest" || true
  fi
done <<< "$MAN_KEYS"

# --- 3. export definitions (optional) --------------------------------------
if [[ -n "$SCOPE" ]]; then
  if az costmanagement export list --scope "$SCOPE" -o json > "$OUT/export_definitions.json" 2>"$OUT/export_definitions.err"; then
    if [[ $HAVE_JQ -eq 1 ]]; then
      jq -c '(.value // .)[] | {name, schedule: .schedule, timeframe: .definition.timeframe, type: .definition.type, format, dest: .deliveryInfo.destination, dataset: .definition.dataSet.granularity}' "$OUT/export_definitions.json" || true
    fi
  else echo "export definitions unavailable (see $OUT/export_definitions.err)" >&2; fi
fi

