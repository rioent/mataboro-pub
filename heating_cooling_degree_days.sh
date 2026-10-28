#!/usr/bin/env bash
set -Eeuo pipefail

# Heating and Cooling Degree Day HTML report
# Default location: Sparrowbush, NY 12780
# Data: National Weather Service API (free; no API key)
# Requirements: bash, curl, jq, awk, GNU date

LAT="${LAT:-41.4420}"
LON="${LON:--74.7240}"
LOCATION="${LOCATION:-Sparrowbush, NY 12780}"
BASE_TEMP_F="${BASE_TEMP_F:-65}"
TIMEZONE="${TIMEZONE:-America/New_York}"
OUTPUT_FILE="${OUTPUT_FILE:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/degree_days.html}"
USER_AGENT="DegreeDayReport/1.0 (local personal weather report)"

for cmd in curl jq awk date; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required command: $cmd" >&2; exit 1; }
done

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
raw="$tmpdir/observations.tsv"
daily="$tmpdir/daily.tsv"
monthly="$tmpdir/monthly.tsv"
: > "$raw"

api_get() {
  curl --fail --silent --show-error --location \
    --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 90 \
    -H "User-Agent: $USER_AGENT" -H 'Accept: application/geo+json' "$1"
}

echo "Finding the nearest NWS observation station..."
point_json="$(api_get "https://api.weather.gov/points/${LAT},${LON}")"
stations_url="$(jq -r '.properties.observationStations // empty' <<<"$point_json")"
[[ -n "$stations_url" ]] || { echo "NWS did not return a station list." >&2; exit 1; }
station_json="$(api_get "$stations_url")"
station_url="$(jq -r '.features[0].id // empty' <<<"$station_json")"
station_id="$(jq -r '.features[0].properties.stationIdentifier // empty' <<<"$station_json")"
station_name="$(jq -r '.features[0].properties.name // empty' <<<"$station_json")"
[[ -n "$station_url" ]] || { echo "No NWS station was found." >&2; exit 1; }

current_month="$(TZ="$TIMEZONE" date +%Y-%m)"
# Current month plus the five prior calendar months (six months total).
start_month="$(TZ="$TIMEZONE" date -d "${current_month}-01 -5 months" +%Y-%m)"
start_date="${start_month}-01"
end_date="$(TZ="$TIMEZONE" date +%Y-%m-%d)"

echo "Downloading NWS observations from $station_id ($station_name)..."
month="$start_month"
while [[ "$month" < "$current_month" || "$month" == "$current_month" ]]; do
  month_start="${month}-01T00:00:00Z"
  next_month="$(date -u -d "${month}-01 +1 month" +%Y-%m)"
  month_end="${next_month}-01T00:00:00Z"
  url="${station_url}/observations?start=${month_start}&end=${month_end}&limit=500"
  pages=0
  while [[ -n "$url" && "$url" != "null" && $pages -lt 10 ]]; do
    page="$(api_get "$url")"
    jq -r '.features[] | [.properties.timestamp, .properties.temperature.value] | @tsv' <<<"$page" >> "$raw"
    url="$(jq -r '.pagination.next // empty' <<<"$page")"
    ((pages+=1))
  done
  month="$next_month"
done

[[ -s "$raw" ]] || { echo "No usable NWS observations were returned." >&2; exit 1; }

# Convert UTC timestamps to local dates and Celsius readings to Fahrenheit.
while IFS=$'\t' read -r timestamp temp_c; do
  [[ -n "$timestamp" && "$temp_c" != "null" && -n "$temp_c" ]] || continue
  local_date="$(TZ="$TIMEZONE" date -d "$timestamp" +%Y-%m-%d 2>/dev/null || true)"
  [[ -n "$local_date" ]] || continue
  temp_f="$(awk -v c="$temp_c" 'BEGIN { printf "%.2f", (c*9/5)+32 }')"
  printf '%s\t%s\n' "$local_date" "$temp_f"
done < "$raw" | sort -k1,1 -k2,2n > "$tmpdir/local.tsv"

# One row per calendar day. Degree days use (daily high + daily low) / 2.
awk -F '\t' -v base="$BASE_TEMP_F" '
  function emit() {
    if (d == "") return
    avg=(lo+hi)/2; hdd=base-avg; cdd=avg-base
    if (hdd<0) hdd=0; if (cdd<0) cdd=0
    printf "%s\t%.1f\t%.1f\t%.1f\t%.1f\t%.1f\t%d\n", d,lo,hi,avg,hdd,cdd,n
  }
  $1!=d { emit(); d=$1; lo=$2; hi=$2; n=0 }
  { if($2<lo)lo=$2; if($2>hi)hi=$2; n++ }
  END { emit() }
' "$tmpdir/local.tsv" > "$daily"

awk -F '\t' '
  { m=substr($1,1,7); h[m]+=$5; c[m]+=$6; days[m]++; readings[m]+=$7 }
  END { for(m in h) printf "%s\t%.1f\t%.1f\t%d\t%d\n",m,h[m],c[m],days[m],readings[m] }
' "$daily" | sort > "$monthly"

generated="$(TZ="$TIMEZONE" date '+%B %-d, %Y at %-I:%M %p %Z')"
max_total="$(awk -F '\t' 'BEGIN{x=1}{if($2>x)x=$2;if($3>x)x=$3}END{print x}' "$monthly")"

{
cat <<HTML
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Heating and Cooling Degree Days - ${LOCATION}</title>
<style>
:root{--navy:#17324d;--blue:#2878b5;--red:#d65a4a;--ink:#18212a;--muted:#607080;--line:#d8e0e7;--bg:#f3f6f8}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.45 system-ui,-apple-system,Segoe UI,sans-serif}.wrap{max-width:1180px;margin:auto;padding:28px 18px 50px}header{background:linear-gradient(135deg,#17324d,#285d82);color:#fff;padding:26px;border-radius:14px;box-shadow:0 8px 24px #16324d25}h1{margin:0 0 5px;font-size:clamp(24px,4vw,38px)}header p{margin:5px 0;color:#e8f1f7}.grid{display:grid;grid-template-columns:1fr 1fr;gap:18px;margin-top:18px}.card{background:#fff;border:1px solid var(--line);border-radius:12px;padding:20px;box-shadow:0 3px 12px #2030400c}h2{margin:0 0 15px;color:var(--navy);font-size:21px}.bars{display:grid;gap:13px}.barrow{display:grid;grid-template-columns:92px 1fr 48px;gap:9px;align-items:center}.track{height:15px;background:#edf1f4;border-radius:9px;overflow:hidden}.bar{height:100%;min-width:2px;border-radius:9px}.hdd{background:var(--blue)}.cdd{background:var(--red)}.legend{display:flex;gap:18px;color:var(--muted);font-size:13px}.dot{display:inline-block;width:10px;height:10px;border-radius:50%;margin-right:5px}table{width:100%;border-collapse:collapse}th,td{padding:9px 10px;border-bottom:1px solid var(--line);text-align:right}th{background:#edf3f7;color:var(--navy);position:sticky;top:0}th:first-child,td:first-child{text-align:left}tr:hover td{background:#f6fafc}.scroll{max-height:680px;overflow:auto;border:1px solid var(--line);border-radius:9px}.note{color:var(--muted);font-size:13px;margin:12px 0 0}.daily{margin-top:18px}.badge{display:inline-block;background:#ffffff20;border:1px solid #ffffff40;padding:3px 9px;border-radius:99px;margin-right:5px}@media(max-width:760px){.grid{grid-template-columns:1fr}.barrow{grid-template-columns:80px 1fr 42px}.wrap{padding:12px}.card,header{padding:15px}th,td{padding:8px 6px;font-size:13px}}
</style></head><body><main class="wrap"><header><h1>Heating &amp; Cooling Degree Days</h1><p>${LOCATION}</p><p><span class="badge">NWS station ${station_id}</span><span class="badge">Base ${BASE_TEMP_F}°F</span><span class="badge">Updated ${generated}</span></p></header>
<section class="grid"><article class="card"><h2>Monthly Summary</h2><table><thead><tr><th>Month</th><th>HDD</th><th>CDD</th><th>Days</th><th>Avg. readings/day</th></tr></thead><tbody>
HTML
awk -F '\t' '{cmd="date -d \""$1"-01\" +\"%B %Y\"";cmd|getline label;close(cmd);printf "<tr><td>%s%s</td><td>%.1f</td><td>%.1f</td><td>%d</td><td>%.1f</td></tr>\n",label,($1=="'"$current_month"'"?" (MTD)":""),$2,$3,$4,$5/$4}' "$monthly"
cat <<HTML
</tbody></table><p class="note">MTD means month to date. Totals cover observed days through ${end_date}.</p></article><article class="card"><h2>Monthly Degree Day Chart</h2><div class="legend"><span><i class="dot hdd"></i>Heating</span><span><i class="dot cdd"></i>Cooling</span></div><div class="bars">
HTML
awk -F '\t' -v max="$max_total" '{cmd="date -d \""$1"-01\" +\"%b %Y\"";cmd|getline label;close(cmd);printf "<div class=barrow><span>%s HDD</span><div class=track><div class=\"bar hdd\" style=\"width:%.1f%%\"></div></div><b>%.0f</b></div>\n",label,100*$2/max,$2;printf "<div class=barrow><span>%s CDD</span><div class=track><div class=\"bar cdd\" style=\"width:%.1f%%\"></div></div><b>%.0f</b></div>\n",label,100*$3/max,$3}' "$monthly"
cat <<HTML
</div></article></section><section class="card daily"><h2>Day-by-Day Detail</h2><div class="scroll"><table><thead><tr><th>Date</th><th>Low °F</th><th>High °F</th><th>Mean °F</th><th>HDD</th><th>CDD</th><th>Readings</th></tr></thead><tbody>
HTML
tac "$daily" | awk -F '\t' '{cmd="date -d \""$1"\" +\"%a, %b %-d, %Y\"";cmd|getline label;close(cmd);printf "<tr><td>%s</td><td>%.1f</td><td>%.1f</td><td>%.1f</td><td>%.1f</td><td>%.1f</td><td>%d</td></tr>\n",label,$2,$3,$4,$5,$6,$7}'
cat <<HTML
</tbody></table></div><p class="note">HDD = max(0, ${BASE_TEMP_F} − daily mean). CDD = max(0, daily mean − ${BASE_TEMP_F}). Daily mean is the average of the observed high and low. Missing or sparse station observations can affect totals. Source: National Weather Service station ${station_id}, ${station_name}.</p></section></main></body></html>
HTML
} > "$OUTPUT_FILE"

echo
echo "Report created successfully:"
echo "$OUTPUT_FILE"
echo "NWS station: $station_id - $station_name"
