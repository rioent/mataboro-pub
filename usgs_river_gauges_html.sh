#!/usr/bin/env bash
#
# USGS river gauge HTML report
# Creates one self-contained HTML page containing:
#   1. Current gage heights for the selected USGS sites
#   2. Six-hour gage-height summaries for the previous five days
#
# Requirements:
#   - Linux
#   - Python 3.9 or newer
#   - Internet access
#
# Run:
#   chmod +x usgs_river_gauges_html.sh
#   ./usgs_river_gauges_html.sh

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_FILE="${SCRIPT_DIR}/usgs_river_gauge_summary.html"
export OUTPUT_FILE

pause_before_exit() {
    local exit_status=$?

    printf '\nPress any key to close terminal...'

    if [[ -t 0 ]]; then
        IFS= read -r -n 1 -s _ || true
    else
        # This fallback helps when a desktop launcher supplies a terminal but
        # does not leave standard input attached to it.
        if { exec 3</dev/tty; } 2>/dev/null; then
            IFS= read -r -n 1 -s -u 3 _ || true
            exec 3<&-
        fi
    fi

    printf '\n'
    return "$exit_status"
}

trap pause_before_exit EXIT

if ! command -v python3 >/dev/null 2>&1; then
    printf 'Error: Python 3 is required but was not found.\n' >&2
    exit 1
fi

printf 'Downloading current and historical USGS river data...\n'

python3 - <<'PYTHON'
from __future__ import annotations

import html
import json
import math
import os
import sys
from collections import defaultdict
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

SITES = [
    "01434000",
    "01432160",
    "01433005",
    "01433500",
    "01437500",
]

FALLBACK_NAMES = {
    "01434000": "Delaware River at Port Jervis, NY",
    "01432160": "Delaware River at Barryville, NY",
    "01433005": "Mongaup River below Swinging Bridge Reservoir, NY",
    "01433500": "Mongaup River near Mongaup, NY",
    "01437500": "Neversink River at Godeffroy, NY",
}

PARAMETER_CODE = "00065"  # Gage height
LOOKBACK = "P5D"
LOCAL_TIMEZONE = "America/New_York"
API_BASE = "https://waterservices.usgs.gov/nwis/iv/"
OUTPUT_FILE = Path(os.environ["OUTPUT_FILE"])


def fail(message: str, exit_code: int = 1) -> None:
    print(f"Error: {message}", file=sys.stderr)
    raise SystemExit(exit_code)


def fetch_json(url: str) -> dict[str, Any]:
    request = Request(
        url,
        headers={
            "User-Agent": "USGS-River-Gauge-HTML-Report/2.0",
            "Accept": "application/json",
        },
    )
    try:
        with urlopen(request, timeout=45) as response:
            charset = response.headers.get_content_charset() or "utf-8"
            return json.loads(response.read().decode(charset))
    except HTTPError as exc:
        fail(f"USGS returned HTTP {exc.code}: {exc.reason}")
    except URLError as exc:
        fail(f"could not reach the USGS service: {exc.reason}")
    except TimeoutError:
        fail("the USGS request timed out")
    except json.JSONDecodeError as exc:
        fail(f"USGS returned invalid JSON: {exc}")
    return {}


def parse_datetime(value: str) -> datetime | None:
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None


def parse_number(value: Any) -> float | None:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(number) or number <= -999000:
        return None
    return number


def format_height(value: float | None, unit: str = "ft") -> str:
    return "No data" if value is None else f"{value:,.2f} {unit}"


def format_age(reading_time: datetime, now: datetime) -> str:
    age_seconds = max(
        0,
        int((now - reading_time.astimezone(now.tzinfo)).total_seconds()),
    )
    minutes = age_seconds // 60
    if minutes < 60:
        return f"{minutes} min old"
    hours, remaining_minutes = divmod(minutes, 60)
    if hours < 24:
        return f"{hours} hr {remaining_minutes} min old"
    days, remaining_hours = divmod(hours, 24)
    return f"{days} day {remaining_hours} hr old"


def floor_to_six_hours(dt: datetime) -> datetime:
    return dt.replace(
        hour=(dt.hour // 6) * 6,
        minute=0,
        second=0,
        microsecond=0,
    )


def qualifiers_text(qualifiers: list[str]) -> str:
    descriptions = {
        "P": "Provisional",
        "A": "Approved",
        "e": "Estimated",
        "E": "Estimated",
        "Ice": "Ice affected",
    }
    rendered = [descriptions.get(item, item) for item in qualifiers]
    return ", ".join(dict.fromkeys(rendered))


def esc(value: Any) -> str:
    return html.escape(str(value), quote=True)


try:
    local_tz = ZoneInfo(LOCAL_TIMEZONE)
    utc_tz = ZoneInfo("UTC")
except ZoneInfoNotFoundError:
    fail(
        "timezone data for America/New_York is unavailable. "
        "Install the system tzdata package and try again."
    )

query = urlencode(
    {
        "format": "json",
        "sites": ",".join(SITES),
        "period": LOOKBACK,
        "parameterCd": PARAMETER_CODE,
        "siteStatus": "all",
    }
)
url = f"{API_BASE}?{query}"
data = fetch_json(url)

series_list = data.get("value", {}).get("timeSeries", [])
if not isinstance(series_list, list):
    fail("the USGS response did not contain a time-series list")

records: dict[str, dict[datetime, tuple[float, list[str]]]] = defaultdict(dict)
names = dict(FALLBACK_NAMES)
units: dict[str, str] = defaultdict(lambda: "ft")

for series in series_list:
    try:
        source = series.get("sourceInfo", {})
        site_codes = source.get("siteCode", [])
        site = str(site_codes[0].get("value", "")) if site_codes else ""
        if site not in SITES:
            continue

        site_name = str(source.get("siteName") or "").strip()
        if site_name:
            names[site] = site_name

        variable = series.get("variable", {})
        variable_codes = variable.get("variableCode", [])
        returned_parameter = (
            str(variable_codes[0].get("value", "")) if variable_codes else ""
        )
        if returned_parameter and returned_parameter != PARAMETER_CODE:
            continue

        units[site] = str(variable.get("unit", {}).get("unitCode") or "ft")

        for group in series.get("values", []):
            for item in group.get("value", []):
                timestamp = parse_datetime(item.get("dateTime"))
                height = parse_number(item.get("value"))
                if timestamp is None or height is None:
                    continue
                qualifiers = [str(q) for q in item.get("qualifiers", [])]
                records[site][timestamp] = (height, qualifiers)
    except (AttributeError, IndexError, TypeError):
        continue

now_local = datetime.now(local_tz)
now_utc = now_local.astimezone(utc_tz)

# Build six-hour blocks covering the full five-day lookback through the
# current partial block.
first_block = floor_to_six_hours(now_local - timedelta(days=5))
last_block = floor_to_six_hours(now_local)
blocks: list[tuple[datetime, datetime]] = []
cursor = first_block
while cursor <= last_block:
    blocks.append((cursor, cursor + timedelta(hours=6)))
    cursor += timedelta(hours=6)

site_readings: dict[str, list[tuple[datetime, float, list[str]]]] = {}
for site in SITES:
    readings = [
        (timestamp.astimezone(local_tz), value, qualifiers)
        for timestamp, (value, qualifiers) in records.get(site, {}).items()
    ]
    readings.sort(key=lambda item: item[0])
    site_readings[site] = readings

current_rows: list[str] = []
for site in SITES:
    readings = site_readings[site]
    monitor_url = f"https://waterdata.usgs.gov/monitoring-location/{site}/"

    if readings:
        reading_time, height, qualifiers = readings[-1]
        qualifier_note = qualifiers_text(qualifiers)
        status = format_age(reading_time, now_local)
        if qualifier_note:
            status = f"{status}; {qualifier_note}"
        height_text = format_height(height, units[site])
        reading_text = reading_time.strftime("%Y-%m-%d %I:%M %p %Z")
    else:
        height_text = "No data"
        reading_text = "No timestamp"
        status = "No valid reading returned"

    current_rows.append(
        "<tr>"
        f'<td><a href="{esc(monitor_url)}" target="_blank" rel="noopener">{esc(site)}</a></td>'
        f"<td>{esc(names[site])}</td>"
        f'<td class="number strong">{esc(height_text)}</td>'
        f"<td>{esc(reading_text)}</td>"
        f"<td>{esc(status)}</td>"
        "</tr>"
    )

history_rows: list[str] = []
for block_start, block_end in reversed(blocks):
    effective_end = min(block_end, now_local + timedelta(minutes=1))
    block_label = (
        f"{block_start:%a, %b %d, %Y %I:%M %p} to "
        f"{block_end:%I:%M %p}"
    )

    cells = [f'<th scope="row">{esc(block_label)}</th>']
    for site in SITES:
        candidates = [
            reading
            for reading in site_readings[site]
            if block_start <= reading[0] < effective_end
        ]
        if not candidates:
            cells.append('<td class="missing">No reading</td>')
            continue

        reading_time, height, qualifiers = candidates[-1]
        qualifier_note = qualifiers_text(qualifiers)
        details = reading_time.strftime("%I:%M %p")
        if qualifier_note:
            details = f"{details} · {qualifier_note}"
        cells.append(
            '<td class="number">'
            f'<span class="history-value">{esc(format_height(height, units[site]))}</span>'
            f'<span class="history-time">{esc(details)}</span>'
            "</td>"
        )

    history_rows.append("<tr>" + "".join(cells) + "</tr>")

site_headers = "".join(
    f'<th scope="col"><span>{esc(site)}</span><small>{esc(names[site])}</small></th>'
    for site in SITES
)

page = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="900">
<title>USGS River Gauge Summary</title>
<style>
    :root {{
        color-scheme: light dark;
        --background: #f4f6f8;
        --panel: #ffffff;
        --text: #1d2733;
        --muted: #5f6b76;
        --border: #cfd7df;
        --header: #173f5f;
        --header-text: #ffffff;
        --row-alt: #eef3f7;
        --link: #0b5f9e;
        --missing: #7a4c00;
        --shadow: 0 2px 10px rgba(0, 0, 0, 0.08);
    }}

    * {{ box-sizing: border-box; }}

    body {{
        margin: 0;
        background: var(--background);
        color: var(--text);
        font-family: Arial, Helvetica, sans-serif;
        line-height: 1.4;
    }}

    main {{
        width: min(1600px, calc(100% - 32px));
        margin: 24px auto 40px;
    }}

    header {{
        margin-bottom: 18px;
        padding: 22px 24px;
        border-radius: 10px;
        background: var(--header);
        color: var(--header-text);
        box-shadow: var(--shadow);
    }}

    h1 {{ margin: 0 0 7px; font-size: clamp(1.6rem, 3vw, 2.35rem); }}
    h2 {{ margin: 0 0 12px; font-size: 1.25rem; }}
    p {{ margin: 5px 0; }}
    header p {{ opacity: 0.92; }}

    section {{
        margin-top: 18px;
        padding: 20px;
        border: 1px solid var(--border);
        border-radius: 10px;
        background: var(--panel);
        box-shadow: var(--shadow);
    }}

    .table-wrap {{ overflow-x: auto; }}

    table {{
        width: 100%;
        border-collapse: collapse;
        font-size: 0.93rem;
    }}

    th, td {{
        padding: 10px 12px;
        border: 1px solid var(--border);
        text-align: left;
        vertical-align: top;
        white-space: nowrap;
    }}

    thead th {{
        position: sticky;
        top: 0;
        z-index: 1;
        background: var(--header);
        color: var(--header-text);
    }}

    tbody tr:nth-child(even) {{ background: var(--row-alt); }}
    tbody th {{ font-weight: 600; }}

    th small {{
        display: block;
        max-width: 230px;
        margin-top: 3px;
        font-size: 0.72rem;
        font-weight: 400;
        opacity: 0.85;
        white-space: normal;
    }}

    a {{ color: var(--link); }}
    .number {{ text-align: right; font-variant-numeric: tabular-nums; }}
    .strong {{ font-weight: 700; }}
    .missing {{ color: var(--missing); font-style: italic; }}

    .history-value,
    .history-time {{ display: block; }}

    .history-value {{ font-weight: 700; }}
    .history-time {{ margin-top: 2px; color: var(--muted); font-size: 0.78rem; }}

    .note {{ color: var(--muted); font-size: 0.9rem; }}

    footer {{
        margin-top: 18px;
        color: var(--muted);
        font-size: 0.86rem;
        text-align: center;
    }}

    @media print {{
        body {{ background: #fff; color: #000; }}
        main {{ width: 100%; margin: 0; }}
        header, section {{ box-shadow: none; }}
        .table-wrap {{ overflow: visible; }}
        thead th {{ position: static; }}
    }}

    @media (prefers-color-scheme: dark) {{
        :root {{
            --background: #101820;
            --panel: #18232e;
            --text: #edf2f6;
            --muted: #b2bec9;
            --border: #40505f;
            --header: #24597d;
            --row-alt: #202e3a;
            --link: #82c8ff;
            --missing: #ffca75;
            --shadow: none;
        }}
    }}
</style>
</head>
<body>
<main>
    <header>
        <h1>USGS River Gauge Summary</h1>
        <p>Generated {esc(now_local.strftime('%A, %B %d, %Y at %I:%M:%S %p %Z'))}</p>
        <p>UTC: {esc(now_utc.strftime('%Y-%m-%d %H:%M:%S UTC'))} · Measurement: gage height, parameter {PARAMETER_CODE}</p>
    </header>

    <section>
        <h2>Current Gage Heights</h2>
        <div class="table-wrap">
            <table>
                <thead>
                    <tr>
                        <th scope="col">USGS Site</th>
                        <th scope="col">Location</th>
                        <th scope="col">Current Height</th>
                        <th scope="col">Reading Time</th>
                        <th scope="col">Status</th>
                    </tr>
                </thead>
                <tbody>
                    {''.join(current_rows)}
                </tbody>
            </table>
        </div>
    </section>

    <section>
        <h2>Six-Hour Levels for the Past Five Days</h2>
        <p class="note">Each cell shows the final valid reading recorded during that six-hour Eastern Time block. Newest blocks appear first.</p>
        <div class="table-wrap">
            <table>
                <thead>
                    <tr>
                        <th scope="col">Six-Hour Block</th>
                        {site_headers}
                    </tr>
                </thead>
                <tbody>
                    {''.join(history_rows)}
                </tbody>
            </table>
        </div>
    </section>

    <footer>
        USGS instantaneous data are provisional and subject to revision. The page refreshes every 15 minutes when left open.
    </footer>
</main>
</body>
</html>
"""

try:
    OUTPUT_FILE.parent.mkdir(parents=True, exist_ok=True)
    temporary_file = OUTPUT_FILE.with_suffix(OUTPUT_FILE.suffix + ".tmp")
    temporary_file.write_text(page, encoding="utf-8")
    os.replace(temporary_file, OUTPUT_FILE)
except OSError as exc:
    fail(f"could not write the HTML report: {exc}")

print(f"HTML report created successfully:\n{OUTPUT_FILE}")
PYTHON

printf '\nOpen the HTML file in any web browser.\n'
