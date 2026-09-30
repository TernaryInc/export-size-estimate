#!/usr/bin/env bash
# Estimate ongoing storage of an AWS CUR / Data Export in S3.
#
# Lists objects under an S3 prefix whose LastModified falls on one UTC day
# (default: last day of last month), sums their sizes, and fetches the
# manifest(s) plus (best effort) the CUR / Data Export definition so you can
# tell whether each day's drop is a full month-to-date dump or just one day.
#
# Auth: whatever the aws CLI already has (AWS_PROFILE, SSO, env vars, ...).
# Needs: aws CLI v2, awk. Optional: jq (prettier manifest/definition summaries).
#
# Usage: aws_cur_size.sh s3://bucket/prefix [-d YYYY-MM-DD] [-o OUTDIR]
#   prefix should be the report folder, e.g. s3://my-bucket/cur/my-report
set -euo pipefail

usage() { sed -n '2,/^set -e/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }

S3_URI=""; DAY=""; OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d) DAY="$2"; shift 2 ;;
    -o) OUT="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    s3://*) S3_URI="$1"; shift ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done
[[ -n "$S3_URI" ]] || usage

if [[ -z "$DAY" ]]; then
  if date -v1d >/dev/null 2>&1; then DAY=$(date -v1d -v-1d +%F)           # BSD/macOS
  else DAY=$(date -d "$(date +%Y-%m-01) -1 day" +%F); fi                   # GNU
fi
[[ "$DAY" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "bad date: $DAY" >&2; exit 1; }

rest="${S3_URI#s3://}"; BUCKET="${rest%%/*}"
PREFIX=""; [[ "$rest" == */* ]] && PREFIX="${rest#*/}"
# --- preflight: check dependencies one by one, fail fast -------------------
need() { # need CMD HINT
  if command -v "$1" >/dev/null 2>&1; then true; else echo "MISSING $1: $2" >&2; exit 1; fi
}
need aws  "install AWS CLI v2 (brew install awscli)"
need awk  "required"
need sed  "required"
need tr   "required"
need sort "required"
need date "required"
if command -v jq >/dev/null 2>&1; then HAVE_JQ=1; else HAVE_JQ=0; fi
ident=$(aws sts get-caller-identity --query Arn --output text 2>&1) \
  || { echo "FAIL aws credentials: $ident" >&2; exit 1; }
aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>"${TMPDIR:-/tmp}/head_bucket.err" \
  || { echo "FAIL cannot access bucket $BUCKET: $(cat "${TMPDIR:-/tmp}/head_bucket.err")" >&2; exit 1; }

OUT="${OUT:-./cur-size-out/${BUCKET}-${DAY}}"
mkdir -p "$OUT/manifests"

echo "s3://$rest day=$DAY out=$OUT"

# --- 1. objects written on that day ---------------------------------------
aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "$PREFIX" --output text \
  --query "Contents[?starts_with(LastModified, '${DAY}')].[Key,Size,LastModified]" > "$OUT/raw_list.txt"
awk -F'\t' 'NF>=3 && $2 ~ /^[0-9]+$/' "$OUT/raw_list.txt" > "$OUT/files.tsv" 

if [[ ! -s "$OUT/files.tsv" ]]; then
  echo "no objects modified on $DAY under s3://$rest (check prefix/date)." >&2
fi

awk -F'\t' '
  function human(b,  u,i){split("B KiB MiB GiB TiB",u," ");i=1;while(b>=1024&&i<5){b/=1024;i++}return sprintf("%.1f %s",b,u[i])}
  {
    kind = ($1 ~ /[Mm]anifest\.json$/) ? "manifest" : "data"
    per="-"; n=split($1,p,"/")
    for(i=1;i<=n;i++){
      if(p[i] ~ /^[0-9]+-[0-9]+$/ && length(p[i])==17) per=p[i]
      else if(p[i] ~ /^BILLING_PERIOD=/) per=substr(p[i],16)
    }
    k=per SUBSEP kind; c[k]++; b[k]+=$2; tc[kind]++; tb[kind]+=$2
  }
  END{
    for(k in c){ split(k,a,SUBSEP); printf "%-18s %-8s %4d files  %10s\n", a[1],a[2],c[k],human(b[k]) | "sort" }
    close("sort")
  }' "$OUT/files.tsv"


# --- 2. manifests -----------------------------------------------------------
MAN_KEYS=$(awk -F'\t' '$1 ~ /[Mm]anifest\.json$/ {print $1}' "$OUT/files.tsv")
if [[ -z "$MAN_KEYS" ]]; then
  echo "no manifest modified on $DAY; using latest" >&2
  MAN_KEYS=$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "$PREFIX" --output text \
    --query "sort_by(Contents[?ends_with(Key, 'anifest.json')], &LastModified)[-1].Key" 2>/dev/null | grep -v '^None$' || true)
fi
while IFS= read -r key; do
  [[ -n "$key" ]] || continue
  dest="$OUT/manifests/$(echo "$key" | tr '/' '_')"
  aws s3 cp "s3://$BUCKET/$key" "$dest" --only-show-errors
  echo "manifest: $key"
  if [[ $HAVE_JQ -eq 1 ]]; then
    jq -c 'with_entries(select(.value|type!="array")) + {arrayLengths: (with_entries(select(.value|type=="array")) | map_values(length))}' "$dest" || true
  fi
done <<< "$MAN_KEYS"

# --- delivery scope + retention ----------------------------------------------
# Every CUR / Data Export refresh delivers the full billing period so far
# (TimeUnit is row granularity, not delivery scope), so one refresh ~= one month
# to date. What varies is how many refreshes are retained (ReportVersioning).
human() { awk -v b="$1" 'BEGIN{split("B KiB MiB GiB TiB",u," ");i=1;while(b>=1024&&i<5){b/=1024;i++}printf "%.1f %s",b,u[i]}'; }
REPORT_NAME=""; BP=""
M1=$(ls "$OUT"/manifests/* 2>/dev/null | head -1 || true)
if [[ -n "$M1" && $HAVE_JQ -eq 1 ]]; then
  REPORT_NAME=$(jq -r '.reportName // .exportName // empty' "$M1")
  BP=$(jq -r 'if .billingPeriod then "\(.billingPeriod.start)..\(.billingPeriod.end)" else empty end' "$M1")
fi
for comp in $(awk -F'\t' '$1 !~ /[Mm]anifest\.json$/ {n=split($1,p,"/"); for(i=1;i<=n;i++) if((p[i] ~ /^[0-9]+-[0-9]+$/ && length(p[i])==17) || p[i] ~ /^BILLING_PERIOD=/) print p[i]}' "$OUT/files.tsv" | sort -u); do
  read -r rb rn < <(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "$PREFIX" --output text \
    --query "Contents[?contains(Key, '/${comp}/')].[Key,Size]" \
    | awk -F'\t' 'NF>=2 && $2 ~ /^[0-9]+$/ { if ($1 ~ /[Mm]anifest\.json$/) m++; else d+=$2 } END{print d+0, m+0}')
  echo "$comp: delivers month-to-date (billingPeriod ${BP:-n/a}); retained $(human "$rb") data in $rn refreshes (avg $(human $((rn>0 ? rb/rn : 0))) each)"
done

# --- 3. report definition (best effort; needs cur:/bcm-data-exports: read perms)
if aws cur describe-report-definitions --region us-east-1 --output json > "$OUT/cur_definitions.json" 2>"$OUT/cur_definitions.err"; then
  if [[ $HAVE_JQ -eq 1 ]]; then
    jq -c --arg b "$BUCKET" --arg n "$REPORT_NAME" '.ReportDefinitions[] | select(.S3Bucket==$b and ($n=="" or .ReportName==$n)) | {ReportName,S3Prefix,TimeUnit,Format,Compression,ReportVersioning,RefreshClosedReports,AdditionalSchemaElements}' "$OUT/cur_definitions.json"
  fi
else echo "cur definitions unavailable (see $OUT/cur_definitions.err)" >&2; fi

if aws bcm-data-exports list-exports --region us-east-1 --query 'Exports[].ExportArn' --output text > "$OUT/bcm_arns.txt" 2>"$OUT/bcm.err"; then
  for arn in $(cat "$OUT/bcm_arns.txt"); do
    f="$OUT/bcm_export_$(basename "$arn").json"
    aws bcm-data-exports get-export --region us-east-1 --export-arn "$arn" --output json > "$f" || continue
    if [[ $HAVE_JQ -eq 1 ]]; then
      jq -c --arg b "$BUCKET" --arg n "$REPORT_NAME" '.Export | select(.DestinationConfigurations.S3Destination.S3Bucket==$b and ($n=="" or .Name==$n)) | {Name, Query: .DataQuery.QueryStatement[0:80], TableConfigurations: .DataQuery.TableConfigurations, Refresh: .RefreshCadence, S3: .DestinationConfigurations.S3Destination}' "$f"
    fi
  done
else echo "bcm exports unavailable (see $OUT/bcm.err)" >&2; fi

