#!/usr/bin/env bash
#
# Ham Radio Net Aggregator
# Polls several public amateur-radio net directories, merges duplicate listings,
# calculates upcoming dates, groups results by band, and leaves the terminal open.
#
# Output:
#   ~/Desktop/Ham_Net_Report/ham_net_report.txt
#   ~/Desktop/Ham_Net_Report/ham_net_report.csv
#   ~/Desktop/Ham_Net_Report/ham_net_report.html
#   ~/Desktop/Ham_Net_Report/source_status.txt
#
# Requirements:
#   bash, curl, python3
#
# Usage:
#   chmod +x ham_net_aggregator.sh
#   ./ham_net_aggregator.sh
#
# Optional:
#   ./ham_net_aggregator.sh --days 21
#   ./ham_net_aggregator.sh --no-pause
#   ./ham_net_aggregator.sh --self-test
#

set -u
set -o pipefail

REPORT_TZ="${REPORT_TZ:-America/New_York}"
LOOKAHEAD_DAYS=14
PAUSE_AT_END=1
SELF_TEST=0

while (($#)); do
    case "$1" in
        --days)
            [[ ${2:-} =~ ^[0-9]+$ ]] || {
                printf 'ERROR: --days requires a whole number.\n' >&2
                exit 2
            }
            LOOKAHEAD_DAYS="$2"
            shift 2
            ;;
        --no-pause)
            PAUSE_AT_END=0
            shift
            ;;
        --self-test)
            SELF_TEST=1
            PAUSE_AT_END=0
            shift
            ;;
        -h|--help)
            sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            printf 'ERROR: Unknown option: %s\n' "$1" >&2
            exit 2
            ;;
    esac
done

for required in curl python3; do
    if ! command -v "$required" >/dev/null 2>&1; then
        printf 'ERROR: Required command not found: %s\n' "$required" >&2
        printf 'On Linux Mint/Ubuntu: sudo apt install curl python3\n' >&2
        exit 1
    fi
done

if [[ -d "${HOME}/Desktop" ]]; then
    OUTPUT_DIR="${HOME}/Desktop/Ham_Net_Report"
else
    OUTPUT_DIR="${HOME}/Ham_Net_Report"
fi

mkdir -p "$OUTPUT_DIR"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ham-net-report.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

RAW_DIR="$WORK_DIR/raw"
mkdir -p "$RAW_DIR"

STATUS_FILE="$OUTPUT_DIR/source_status.txt"
TEXT_REPORT="$OUTPUT_DIR/ham_net_report.txt"
CSV_REPORT="$OUTPUT_DIR/ham_net_report.csv"
HTML_REPORT="$OUTPUT_DIR/ham_net_report.html"
MANIFEST="$WORK_DIR/manifest.tsv"
: > "$STATUS_FILE"
: > "$MANIFEST"

printf '\033[1;36mHam Radio Net Aggregator\033[0m\n'
printf 'Report time zone: %s\n' "$REPORT_TZ"
printf 'Upcoming date window: %s days\n\n' "$LOOKAHEAD_DAYS"

fetch_source() {
    local source_id="$1"
    local source_name="$2"
    local url="$3"
    local destination="$RAW_DIR/${source_id}.html"
    local http_code rc

    printf 'Polling %-28s ' "$source_name"

    http_code="$(
        curl \
            --location \
            --silent \
            --show-error \
            --compressed \
            --connect-timeout 12 \
            --max-time 35 \
            --retry 2 \
            --retry-delay 2 \
            --user-agent 'Mozilla/5.0 (X11; Linux x86_64) HamNetAggregator/1.0' \
            --output "$destination" \
            --write-out '%{http_code}' \
            "$url" 2>>"$STATUS_FILE"
    )"
    rc=$?

    if [[ $rc -eq 0 && "$http_code" =~ ^2[0-9][0-9]$ && -s "$destination" ]]; then
        printf '\033[32mOK\033[0m\n'
        printf '%s\t%s\t%s\t%s\n' \
            "$source_id" "$source_name" "$url" "$destination" >> "$MANIFEST"
        printf 'OK\t%s\t%s\tHTTP %s\n' \
            "$source_name" "$url" "$http_code" >> "$STATUS_FILE"
        return 0
    fi

    printf '\033[33mUNAVAILABLE\033[0m\n'
    printf 'FAILED\t%s\t%s\tcurl=%s HTTP=%s\n' \
        "$source_name" "$url" "$rc" "${http_code:-none}" >> "$STATUS_FILE"
    rm -f "$destination"
    return 1
}

if (( SELF_TEST )); then
    cat > "$RAW_DIR/self_test.html" <<'EOF'
<html><body>
<table>
<tr><th>Net Name</th><th>Frequency</th><th>Time</th><th>Schedule</th><th>Mode</th></tr>
<tr><td>Test 40 Meter Net</td><td>7.255 MHz</td><td>7:00 PM</td><td>Monday</td><td>SSB</td></tr>
</table>
</body></html>
EOF
    printf 'self_test\tSelf-test fixture\thttps://example.invalid/self-test\t%s\n' \
        "$RAW_DIR/self_test.html" >> "$MANIFEST"
    printf 'OK\tSelf-test fixture\tLocal fixture\n' >> "$STATUS_FILE"
else
    # Broad public directories and live-net sources.
    fetch_source "netlogger" \
        "NetLogger active nets" \
        "https://www.netlogger.org/" || true

    fetch_source "northeast" \
        "Northeast Net Directory" \
        "https://w2blc.net/nenets.htm" || true

    fetch_source "rac" \
        "Radio Amateurs of Canada" \
        "https://www.rac.ca/nets/" || true

    fetch_source "care" \
        "CARE Net Directory" \
        "https://carehamradio.com/general-net-list-for-area/" || true

    fetch_source "smarc" \
        "SMARC HF Nets" \
        "https://smarc.org/hf-nets/" || true

    fetch_source "midisland" \
        "Mid-Island Radio Nets" \
        "https://midislandradio.ca/other-radio-nets/" || true

    fetch_source "arrl" \
        "ARRL Net Directory" \
        "https://www.arrl.org/arrl-net-directory-search" || true

    # NetFinder is paginated. Stop after two consecutive empty/failed pages.
    empty_pages=0
    for page in $(seq 1 25); do
        if (( page == 1 )); then
            url="https://netfinder.radio/nets"
        else
            url="https://netfinder.radio/nets?page=${page}"
        fi

        source_id="netfinder_${page}"
        source_name="NetFinder page ${page}"

        if fetch_source "$source_id" "$source_name" "$url"; then
            if grep -qiE 'No nets|No results|Nets[^<]{0,20}</' "$RAW_DIR/${source_id}.html"; then
                ((empty_pages+=1))
            else
                empty_pages=0
            fi
        else
            ((empty_pages+=1))
        fi

        (( empty_pages >= 2 )) && break
        sleep 0.20
    done
fi

printf '\nProcessing and normalizing listings...\n'

python3 - "$MANIFEST" "$TEXT_REPORT" "$CSV_REPORT" "$HTML_REPORT" \
    "$STATUS_FILE" "$REPORT_TZ" "$LOOKAHEAD_DAYS" <<'PY'
from __future__ import annotations

import csv
import html
import json
import re
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from html.parser import HTMLParser
from pathlib import Path
from typing import Iterable, Optional
from urllib.parse import urljoin
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


MANIFEST = Path(sys.argv[1])
TEXT_REPORT = Path(sys.argv[2])
CSV_REPORT = Path(sys.argv[3])
HTML_REPORT = Path(sys.argv[4])
STATUS_FILE = Path(sys.argv[5])
REPORT_TZ_NAME = sys.argv[6]
LOOKAHEAD_DAYS = max(1, int(sys.argv[7]))

try:
    REPORT_TZ = ZoneInfo(REPORT_TZ_NAME)
except ZoneInfoNotFoundError:
    REPORT_TZ_NAME = "America/New_York"
    REPORT_TZ = ZoneInfo(REPORT_TZ_NAME)

NOW = datetime.now(REPORT_TZ)
GENERATED = NOW.strftime("%A, %B %-d, %Y at %-I:%M %p %Z")

DAY_NAMES = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
DAY_ABBR = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

SOURCE_DEFAULT_TZ = {
    "northeast": "America/New_York",
    "netlogger": "UTC",
    "arrl": "America/New_York",
    "care": None,
    "smarc": None,
    "midisland": None,
    "rac": None,
    "self_test": "America/New_York",
}

BAND_ORDER = {
    "2200 m": 0,
    "630 m": 1,
    "160 m": 2,
    "80/75 m": 3,
    "60 m": 4,
    "40 m": 5,
    "30 m": 6,
    "20 m": 7,
    "17 m": 8,
    "15 m": 9,
    "12 m": 10,
    "10 m": 11,
    "6 m": 12,
    "2 m": 13,
    "1.25 m": 14,
    "70 cm": 15,
    "33 cm": 16,
    "23 cm": 17,
    "Microwave": 18,
    "Multi-band": 19,
    "Internet / Linked": 20,
    "Unknown": 21,
}

TIME_PATTERN = re.compile(
    r"""(?ix)
    \b(
        (?:[01]?\d|2[0-3]):[0-5]\d(?:\s*(?:AM|PM))?
        |
        (?:1[0-2]|0?[1-9])\s*(?:AM|PM)
        |
        [0-2]?\d[0-5]\d\s*(?:Z|UTC|GMT)
    )\b
    """
)

FREQUENCY_PATTERN = re.compile(
    r"""(?ix)
    (?<![\d.])
    (
        \d{1,4}(?:\.\d{1,5})?
    )
    \s*
    (MHz|kHz|GHz)?
    (?![\d.])
    """
)

DAY_WORD_PATTERN = re.compile(
    r"""(?ix)
    \b(
        daily|nightly|weekdays?|weekends?|
        every\s+day|seven\s+days(?:\s+a\s+week)?|
        mon(?:day)?|tue(?:sday)?|wed(?:nesday)?|
        thu(?:rsday)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?|
        m\s*[-–]\s*(?:f|fri|sat)|mon\s*[-–]\s*(?:fri|sat)|
        every\s+other\s+week|every\s+two\s+weeks|biweekly
    )\b
    """
)

MODE_WORDS = [
    "SSB", "USB", "LSB", "CW", "AM", "FM", "DMR", "D-STAR", "DSTAR",
    "Fusion", "YSF", "P25", "NXDN", "FT8", "FT4", "RTTY", "PSK31",
    "Winlink", "Packet", "EchoLink", "AllStar", "IRLP", "M17", "Digital",
]

NETWORK_WORDS = ["EchoLink", "AllStar", "IRLP", "DMR", "D-STAR", "DSTAR", "Fusion", "YSF", "Internet"]


def clean_text(value: str) -> str:
    value = html.unescape(value or "")
    value = value.replace("\xa0", " ")
    value = re.sub(r"[\t\r\f\v]+", " ", value)
    value = re.sub(r" {2,}", " ", value)
    return value.strip(" \n|,;")


def normalized_name(value: str) -> str:
    value = clean_text(value)
    value = re.sub(r"\s+", " ", value)
    return value


def safe_float(value: str) -> Optional[float]:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def convert_frequency_to_mhz(number: float, unit: Optional[str]) -> Optional[float]:
    unit_norm = (unit or "").lower()
    if unit_norm == "ghz":
        mhz = number * 1000.0
    elif unit_norm == "khz":
        mhz = number / 1000.0
    elif unit_norm == "mhz":
        mhz = number
    else:
        # Common directory convention: 3905 means 3905 kHz; 145.170 means MHz.
        if 1800 <= number <= 999999:
            mhz = number / 1000.0
        else:
            mhz = number

    if 0.135 <= mhz <= 300000:
        return mhz
    return None


def extract_frequencies(text: str) -> list[float]:
    results: list[float] = []
    for match in FREQUENCY_PATTERN.finditer(text):
        raw_num, unit = match.groups()
        number = safe_float(raw_num)
        if number is None:
            continue

        # Reject obvious years, clock-like values, and band labels such as
        # "40 Meter" or "2 m".
        start, end = match.span()
        before = text[max(0, start - 10):start].lower()
        after = text[end:min(len(text), end + 14)].lower()
        around = before + text[start:end].lower() + after
        if unit is None and number in range(1900, 2101) and "khz" not in around:
            continue
        if (start > 0 and text[start - 1] == ":") or (end < len(text) and text[end] == ":"):
            continue
        if unit is None and re.match(r"\s*(?:meters?|metres?|m\b|cm\b)", after):
            continue

        mhz = convert_frequency_to_mhz(number, unit)
        if mhz is None:
            continue

        # Amateur allocations, common repeater ranges, and microwave values.
        if mhz < 0.135:
            continue
        results.append(mhz)

    deduped: list[float] = []
    for value in results:
        if not any(abs(value - old) < 0.00001 for old in deduped):
            deduped.append(value)
    return deduped


def format_frequency(mhz: Optional[float]) -> str:
    if mhz is None:
        return "Not listed"
    if mhz < 1:
        return f"{mhz * 1000:.1f} kHz"
    if mhz < 30:
        return f"{mhz:.4f}".rstrip("0").rstrip(".") + " MHz"
    if mhz < 1000:
        return f"{mhz:.4f}".rstrip("0").rstrip(".") + " MHz"
    return f"{mhz / 1000:.4f}".rstrip("0").rstrip(".") + " GHz"


def infer_band(mhz: Optional[float], text: str = "") -> str:
    explicit = clean_text(text).lower()
    explicit_rules = [
        (r"\b2200\s*m", "2200 m"),
        (r"\b630\s*m", "630 m"),
        (r"\b160\s*m", "160 m"),
        (r"\b(?:80|75)\s*m", "80/75 m"),
        (r"\b60\s*m", "60 m"),
        (r"\b40\s*m", "40 m"),
        (r"\b30\s*m", "30 m"),
        (r"\b20\s*m", "20 m"),
        (r"\b17\s*m", "17 m"),
        (r"\b15\s*m", "15 m"),
        (r"\b12\s*m", "12 m"),
        (r"\b10\s*m", "10 m"),
        (r"\b6\s*m", "6 m"),
        (r"\b2\s*m", "2 m"),
        (r"\b1\.25\s*m|\b220\s*mhz", "1.25 m"),
        (r"\b70\s*cm|\b440\b", "70 cm"),
        (r"\b33\s*cm|\b900\b", "33 cm"),
        (r"\b23\s*cm|\b1\.2\s*ghz", "23 cm"),
        (r"\bmulti[- ]band", "Multi-band"),
    ]
    for pattern, label in explicit_rules:
        if re.search(pattern, explicit, re.I):
            return label

    if mhz is None:
        if any(word.lower() in explicit for word in NETWORK_WORDS):
            return "Internet / Linked"
        return "Unknown"

    ranges = [
        (0.1357, 0.1378, "2200 m"),
        (0.472, 0.479, "630 m"),
        (1.8, 2.0, "160 m"),
        (3.5, 4.0, "80/75 m"),
        (5.3, 5.5, "60 m"),
        (7.0, 7.3, "40 m"),
        (10.1, 10.15, "30 m"),
        (14.0, 14.35, "20 m"),
        (18.068, 18.168, "17 m"),
        (21.0, 21.45, "15 m"),
        (24.89, 24.99, "12 m"),
        (28.0, 29.7, "10 m"),
        (50.0, 54.0, "6 m"),
        (144.0, 148.0, "2 m"),
        (219.0, 225.0, "1.25 m"),
        (420.0, 450.0, "70 cm"),
        (902.0, 928.0, "33 cm"),
        (1240.0, 1300.0, "23 cm"),
    ]
    for low, high, label in ranges:
        if low <= mhz <= high:
            return label
    if mhz > 1300:
        return "Microwave"
    return "Unknown"


def infer_mode(text: str) -> str:
    found = []
    for mode in MODE_WORDS:
        if re.search(rf"(?i)(?<![A-Z0-9]){re.escape(mode)}(?![A-Z0-9])", text):
            label = "D-STAR" if mode.upper() in {"DSTAR", "D-STAR"} else mode
            if label not in found:
                found.append(label)
    return ", ".join(found) if found else "Not listed"


def infer_timezone(text: str, source_id: str) -> tuple[Optional[str], str]:
    lower = text.lower()

    named = [
        (r"\b(?:utc|gmt|zulu)\b|(?<=\d)z\b", "UTC", "UTC"),
        (r"\b(?:eastern|est|edt|et)\b", "America/New_York", "Eastern"),
        (r"\b(?:central|cst|cdt|ct)\b", "America/Chicago", "Central"),
        (r"\b(?:mountain|mst|mdt|mt)\b", "America/Denver", "Mountain"),
        (r"\b(?:pacific|pst|pdt|pt)\b", "America/Los_Angeles", "Pacific"),
        (r"\batlantic|ast|adt\b", "America/Halifax", "Atlantic"),
    ]
    for pattern, zone, label in named:
        if re.search(pattern, lower, re.I):
            return zone, label

    default = SOURCE_DEFAULT_TZ.get(source_id)
    if default is None and source_id.startswith("netfinder_"):
        default = SOURCE_DEFAULT_TZ.get("netfinder")
    if default:
        return default, "Eastern" if default == "America/New_York" else "UTC"
    if "local" in lower:
        return None, "Local time, zone not stated"
    return None, "Time zone not stated"


def normalize_time(raw: str) -> Optional[tuple[int, int, str]]:
    if not raw:
        return None
    value = clean_text(raw).upper().replace(".", "")
    value = re.sub(r"\s+", " ", value)

    # 2300Z / 2300 UTC
    match = re.fullmatch(r"([0-2]?\d)([0-5]\d)\s*(Z|UTC|GMT)", value)
    if match:
        hour = int(match.group(1))
        minute = int(match.group(2))
        if hour <= 23:
            return hour, minute, f"{hour:02d}:{minute:02d}"

    # 7 PM
    match = re.fullmatch(r"(1[0-2]|0?[1-9])\s*(AM|PM)", value)
    if match:
        hour = int(match.group(1))
        minute = 0
        ampm = match.group(2)
        if ampm == "AM":
            hour = 0 if hour == 12 else hour
        else:
            hour = 12 if hour == 12 else hour + 12
        return hour, minute, f"{hour:02d}:{minute:02d}"

    # 7:30 PM or 19:30
    match = re.fullmatch(r"([0-2]?\d):([0-5]\d)\s*(AM|PM)?", value)
    if match:
        hour = int(match.group(1))
        minute = int(match.group(2))
        ampm = match.group(3)
        if ampm:
            if not 1 <= hour <= 12:
                return None
            if ampm == "AM":
                hour = 0 if hour == 12 else hour
            else:
                hour = 12 if hour == 12 else hour + 12
        elif hour > 23:
            return None
        return hour, minute, f"{hour:02d}:{minute:02d}"

    return None


def extract_time(text: str) -> str:
    match = TIME_PATTERN.search(text)
    return clean_text(match.group(1)) if match else ""


def extract_schedule(text: str) -> str:
    text = clean_text(text)
    matches = [clean_text(m.group(1)) for m in DAY_WORD_PATTERN.finditer(text)]
    if not matches:
        return ""
    unique = []
    for item in matches:
        item_key = item.lower()
        if item_key not in [x.lower() for x in unique]:
            unique.append(item)
    return ", ".join(unique)


def parse_days(schedule: str) -> Optional[set[int]]:
    value = clean_text(schedule).lower()
    value = value.replace("–", "-")

    if not value:
        return None
    if any(token in value for token in ["every other week", "every two weeks", "biweekly"]):
        return None
    if any(token in value for token in ["daily", "nightly", "every day", "seven days"]):
        return set(range(7))
    if "weekday" in value or re.search(r"\bm\s*-\s*f\b|\bmon\s*-\s*fri\b", value):
        return set(range(5))
    if "weekend" in value:
        return {5, 6}
    if re.search(r"\bm\s*-\s*sat\b|\bmon\s*-\s*sat\b", value):
        return set(range(6))

    mapping = {
        "mon": 0, "monday": 0,
        "tue": 1, "tues": 1, "tuesday": 1,
        "wed": 2, "wednesday": 2,
        "thu": 3, "thur": 3, "thurs": 3, "thursday": 3,
        "fri": 4, "friday": 4,
        "sat": 5, "saturday": 5,
        "sun": 6, "sunday": 6,
    }

    days = set()
    for token, number in mapping.items():
        if re.search(rf"\b{re.escape(token)}\b", value):
            days.add(number)
    return days or None


def human_days(days: Optional[set[int]], original: str) -> str:
    if days is None:
        return original or "Not stated"
    if days == set(range(7)):
        return "Daily"
    if days == set(range(5)):
        return "Monday-Friday"
    if days == set(range(6)):
        return "Monday-Saturday"
    if days == {5, 6}:
        return "Saturday-Sunday"
    return ", ".join(DAY_NAMES[d] for d in sorted(days))


def display_12h(hour: int, minute: int) -> str:
    suffix = "AM" if hour < 12 else "PM"
    shown = hour % 12 or 12
    return f"{shown}:{minute:02d} {suffix}"


def next_occurrences(
    days: Optional[set[int]],
    raw_time: str,
    zone_name: Optional[str],
    count_limit: int = 8,
) -> tuple[str, str]:
    parsed = normalize_time(raw_time)
    if days is None or parsed is None:
        return "See schedule/source", ""

    hour, minute, _ = parsed

    if zone_name is None:
        dates = []
        cursor = NOW.date()
        for offset in range(LOOKAHEAD_DAYS + 1):
            date_value = cursor + timedelta(days=offset)
            if date_value.weekday() in days:
                dates.append(f"{DAY_ABBR[date_value.weekday()]} {date_value.strftime('%b')} {date_value.day}")
                if len(dates) >= count_limit:
                    break
        return "; ".join(dates) or "No occurrence in date window", "Time zone not stated"

    try:
        source_tz = ZoneInfo(zone_name)
    except ZoneInfoNotFoundError:
        source_tz = REPORT_TZ

    source_now = NOW.astimezone(source_tz)
    occurrences = []

    for offset in range(LOOKAHEAD_DAYS + 1):
        source_date = source_now.date() + timedelta(days=offset)
        if source_date.weekday() not in days:
            continue

        source_dt = datetime(
            source_date.year, source_date.month, source_date.day,
            hour, minute, tzinfo=source_tz
        )
        if source_dt < source_now - timedelta(minutes=1):
            continue

        report_dt = source_dt.astimezone(REPORT_TZ)
        occurrences.append(
            f"{DAY_ABBR[report_dt.weekday()]} "
            f"{report_dt.strftime('%b')} {report_dt.day}, "
            f"{display_12h(report_dt.hour, report_dt.minute)} "
            f"{report_dt.tzname() or REPORT_TZ_NAME}"
        )
        if len(occurrences) >= count_limit:
            break

    return "; ".join(occurrences) or "No occurrence in date window", REPORT_TZ_NAME


class TableExtractor(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.in_table = 0
        self.in_row = False
        self.in_cell = False
        self.current_cell: list[str] = []
        self.current_row: list[str] = []
        self.rows: list[list[str]] = []
        self.links: list[str] = []

    def handle_starttag(self, tag: str, attrs) -> None:
        attrs_dict = dict(attrs)
        if tag == "table":
            self.in_table += 1
        elif tag == "tr" and self.in_table:
            self.in_row = True
            self.current_row = []
        elif tag in {"td", "th"} and self.in_row:
            self.in_cell = True
            self.current_cell = []
            for attr_name in ("data-sort", "data-order", "aria-label", "title"):
                if attrs_dict.get(attr_name):
                    self.current_cell.append(str(attrs_dict[attr_name]))
        elif tag == "br" and self.in_cell:
            self.current_cell.append(" / ")
        elif tag == "a" and attrs_dict.get("href"):
            self.links.append(attrs_dict["href"])

    def handle_endtag(self, tag: str) -> None:
        if tag in {"td", "th"} and self.in_cell:
            self.current_row.append(clean_text(" ".join(self.current_cell)))
            self.in_cell = False
            self.current_cell = []
        elif tag == "tr" and self.in_row:
            row = [clean_text(cell) for cell in self.current_row]
            if any(row):
                self.rows.append(row)
            self.in_row = False
            self.current_row = []
        elif tag == "table" and self.in_table:
            self.in_table -= 1

    def handle_data(self, data: str) -> None:
        if self.in_cell:
            self.current_cell.append(data)


class TextExtractor(HTMLParser):
    BLOCK_TAGS = {
        "p", "div", "li", "tr", "td", "th", "br", "h1", "h2", "h3", "h4",
        "h5", "h6", "section", "article", "header", "footer",
    }

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []
        self.links: list[str] = []

    def handle_starttag(self, tag: str, attrs) -> None:
        attrs_dict = dict(attrs)
        if tag in self.BLOCK_TAGS:
            self.parts.append("\n")
        if tag == "a" and attrs_dict.get("href"):
            self.links.append(attrs_dict["href"])

    def handle_endtag(self, tag: str) -> None:
        if tag in self.BLOCK_TAGS:
            self.parts.append("\n")

    def handle_data(self, data: str) -> None:
        self.parts.append(data)

    def text(self) -> str:
        value = "".join(self.parts)
        lines = [clean_text(line) for line in value.splitlines()]
        return "\n".join(line for line in lines if line)


@dataclass
class NetEntry:
    name: str
    frequency_mhz: Optional[float]
    band: str
    mode: str
    schedule_raw: str
    days: Optional[set[int]]
    time_raw: str
    timezone_name: Optional[str]
    timezone_label: str
    source_names: set[str] = field(default_factory=set)
    source_urls: set[str] = field(default_factory=set)
    notes: set[str] = field(default_factory=set)
    active_date: str = ""
    confidence: str = "Directory listing"

    @property
    def frequency_display(self) -> str:
        return format_frequency(self.frequency_mhz)

    @property
    def days_display(self) -> str:
        return human_days(self.days, self.schedule_raw)

    @property
    def listed_time_display(self) -> str:
        if not self.time_raw:
            return "Not stated"
        parsed = normalize_time(self.time_raw)
        if parsed:
            hour, minute, _ = parsed
            return f"{display_12h(hour, minute)} {self.timezone_label}"
        return f"{self.time_raw} {self.timezone_label}".strip()

    @property
    def next_dates(self) -> str:
        if self.active_date:
            return self.active_date
        dates, _ = next_occurrences(self.days, self.time_raw, self.timezone_name)
        return dates


def plausible_name(value: str) -> bool:
    lower = clean_text(value).lower()
    if not lower or len(lower) < 3:
        return False
    header_terms = {
        "name", "net name", "frequency", "start time", "schedule", "type",
        "mode", "band", "days", "utc", "extras",
    }
    if lower in header_terms:
        return False
    if re.fullmatch(r"[\d\s.:/-]+", lower):
        return False
    return True


def choose_name(cells: list[str], row_text: str) -> str:
    for cell in cells:
        if plausible_name(cell):
            # Avoid cells that are only schedule or band text.
            if extract_frequencies(cell):
                continue
            if TIME_PATTERN.fullmatch(clean_text(cell)):
                continue
            if clean_text(cell).lower() in {
                "daily", "controlled", "rag chew", "traffic", "ssb", "cw", "fm",
            }:
                continue
            return normalized_name(cell)[:160]

    before_frequency = re.split(
        r"\b\d{1,4}(?:\.\d+)?\s*(?:MHz|kHz|GHz)?\b",
        row_text,
        maxsplit=1,
        flags=re.I,
    )[0]
    return normalized_name(before_frequency)[:160]


def add_entry(
    entries: list[NetEntry],
    *,
    name: str,
    row_text: str,
    frequency_mhz: Optional[float],
    source_id: str,
    source_name: str,
    source_url: str,
    schedule_raw: str = "",
    time_raw: str = "",
    mode: str = "",
    band_text: str = "",
    notes: str = "",
    active_date: str = "",
    confidence: str = "Directory listing",
) -> None:
    name = normalized_name(name)
    if not plausible_name(name):
        return

    if not schedule_raw:
        schedule_raw = extract_schedule(row_text)
    if not time_raw:
        time_raw = extract_time(row_text)
    if not mode:
        mode = infer_mode(row_text)
    if not band_text:
        band_text = row_text

    timezone_name, timezone_label = infer_timezone(row_text, source_id)
    days = parse_days(schedule_raw)
    band = infer_band(frequency_mhz, band_text)

    # Keep useful internet-linked nets even if no RF frequency is listed.
    if frequency_mhz is None and band == "Unknown":
        if not any(word.lower() in row_text.lower() for word in NETWORK_WORDS):
            return
        band = "Internet / Linked"

    entry = NetEntry(
        name=name,
        frequency_mhz=frequency_mhz,
        band=band,
        mode=mode or "Not listed",
        schedule_raw=schedule_raw,
        days=days,
        time_raw=time_raw,
        timezone_name=timezone_name,
        timezone_label=timezone_label,
        source_names={source_name},
        source_urls={source_url},
        notes={notes} if notes else set(),
        active_date=active_date,
        confidence=confidence,
    )
    entries.append(entry)


def parse_netlogger(
    rows: list[list[str]],
    source_id: str,
    source_name: str,
    source_url: str,
) -> list[NetEntry]:
    entries: list[NetEntry] = []
    for row in rows:
        joined = " | ".join(row)
        if "Start Time" in joined or len(row) < 4:
            continue

        frequencies = extract_frequencies(joined)
        if not frequencies:
            continue

        name = choose_name(row, joined)
        if not name:
            continue

        active_match = re.search(
            r"\b(20\d{2}-\d{2}-\d{2})\s+([0-2]\d:[0-5]\d(?::[0-5]\d)?)\b",
            joined,
        )
        active_date = ""
        if active_match:
            try:
                utc_dt = datetime.fromisoformat(
                    f"{active_match.group(1)}T{active_match.group(2)}+00:00"
                )
                local_dt = utc_dt.astimezone(REPORT_TZ)
                active_date = (
                    f"Active when polled: {local_dt.strftime('%a %b')} "
                    f"{local_dt.day}, {display_12h(local_dt.hour, local_dt.minute)} "
                    f"{local_dt.tzname()}"
                )
            except ValueError:
                active_date = f"Active when polled: {active_match.group(0)} UTC"

        add_entry(
            entries,
            name=name,
            row_text=joined + " UTC",
            frequency_mhz=frequencies[0],
            source_id=source_id,
            source_name=source_name,
            source_url=source_url,
            schedule_raw="Active now; recurring schedule not stated",
            time_raw=active_match.group(2)[:5] if active_match else "",
            mode=infer_mode(joined),
            band_text=joined,
            notes="Live activity listing; it does not prove the usual recurring schedule.",
            active_date=active_date or "Active when source was polled",
            confidence="Live activity",
        )
    return entries


def parse_table_rows(
    rows: list[list[str]],
    source_id: str,
    source_name: str,
    source_url: str,
) -> list[NetEntry]:
    entries: list[NetEntry] = []

    for row in rows:
        if not row:
            continue
        joined = " | ".join(cell for cell in row if cell)
        lower = joined.lower()

        if any(term in lower for term in ["net name frequency", "name days utc", "start time schedule"]):
            continue

        frequencies = extract_frequencies(joined)
        explicit_band = infer_band(None, joined)

        # Some linked/repeater nets have no RF frequency on the directory row.
        if not frequencies and explicit_band in {"Unknown"}:
            if not any(word.lower() in lower for word in NETWORK_WORDS):
                continue

        name = choose_name(row, joined)
        if not name:
            continue

        frequency = frequencies[0] if frequencies else None
        schedule = extract_schedule(joined)
        time_value = extract_time(joined)

        # NetFinder table cells may use bare 24-hour UTC time.
        if source_id.startswith("netfinder") and not time_value:
            for cell in row:
                candidate = clean_text(cell)
                if re.fullmatch(r"(?:[01]\d|2[0-3]):[0-5]\d", candidate):
                    time_value = candidate
                    joined += " UTC"
                    break

        add_entry(
            entries,
            name=name,
            row_text=joined,
            frequency_mhz=frequency,
            source_id=source_id,
            source_name=source_name,
            source_url=source_url,
            schedule_raw=schedule,
            time_raw=time_value,
            mode=infer_mode(joined),
            band_text=joined,
        )

    return entries


def parse_prose(
    page_text: str,
    source_id: str,
    source_name: str,
    source_url: str,
) -> list[NetEntry]:
    entries: list[NetEntry] = []
    lines = [clean_text(x) for x in page_text.splitlines() if clean_text(x)]

    seen_windows = set()
    for i in range(len(lines)):
        # Combining adjacent lines catches headings followed by schedule details.
        window_lines = lines[max(0, i - 1): min(len(lines), i + 3)]
        window = " | ".join(window_lines)
        window_key = window.lower()
        if window_key in seen_windows:
            continue
        seen_windows.add(window_key)

        if "net" not in window.lower():
            continue

        frequencies = extract_frequencies(window)
        if not frequencies and not any(word.lower() in window.lower() for word in NETWORK_WORDS):
            continue

        has_schedule_signal = bool(
            extract_time(window)
            or extract_schedule(window)
            or re.search(r"\b(?:daily|weekly|monthly|local time|utc|gmt)\b", window, re.I)
        )
        if not has_schedule_signal:
            continue

        # Prefer the segment ending in "Net" as the name.
        candidates = re.findall(
            r"([A-Z0-9][A-Za-z0-9&/'().,\- ]{2,100}\bNet)\b",
            window,
            re.I,
        )
        name = normalized_name(candidates[-1]) if candidates else ""
        if not name:
            name = choose_name(window_lines, window)
        if not name:
            continue

        add_entry(
            entries,
            name=name,
            row_text=window,
            frequency_mhz=frequencies[0] if frequencies else None,
            source_id=source_id,
            source_name=source_name,
            source_url=source_url,
            schedule_raw=extract_schedule(window),
            time_raw=extract_time(window),
            mode=infer_mode(window),
            band_text=window,
            notes="Parsed from public page text; check the linked source when details are incomplete.",
        )

    return entries


def net_key(entry: NetEntry) -> tuple:
    name = re.sub(r"[^a-z0-9]+", "", entry.name.lower())
    frequency = round(entry.frequency_mhz or 0.0, 4)
    time_value = normalize_time(entry.time_raw)
    time_key = time_value[2] if time_value else clean_text(entry.time_raw).lower()
    days_key = tuple(sorted(entry.days)) if entry.days is not None else clean_text(entry.schedule_raw).lower()
    return name, frequency, time_key, days_key


def merge_entries(entries: Iterable[NetEntry]) -> list[NetEntry]:
    merged: dict[tuple, NetEntry] = {}

    for entry in entries:
        key = net_key(entry)
        if key not in merged:
            merged[key] = entry
            continue

        current = merged[key]
        current.source_names.update(entry.source_names)
        current.source_urls.update(entry.source_urls)
        current.notes.update(entry.notes)

        if current.mode == "Not listed" and entry.mode != "Not listed":
            current.mode = entry.mode
        elif entry.mode != "Not listed":
            modes = [clean_text(x) for x in (current.mode + "," + entry.mode).split(",")]
            current.mode = ", ".join(dict.fromkeys(x for x in modes if x))

        if current.band in {"Unknown", "Internet / Linked"} and entry.band not in {"Unknown"}:
            current.band = entry.band
        if not current.active_date and entry.active_date:
            current.active_date = entry.active_date
        if current.confidence != "Live activity" and entry.confidence == "Live activity":
            current.confidence = "Live activity"

    return list(merged.values())


def add_manual_verified_entries(entries: list[NetEntry]) -> None:
    # User-requested, independently listed by multiple public sources.
    entries.append(
        NetEntry(
            name="New England Weather Net",
            frequency_mhz=3.905,
            band="80/75 m",
            mode="SSB",
            schedule_raw="Monday-Saturday",
            days=set(range(6)),
            time_raw="5:30 AM",
            timezone_name="America/New_York",
            timezone_label="Eastern",
            source_names={
                "ARRL ARES E-Letter",
                "Northeast Net Directory",
                "New England Weather Net community listing",
            },
            source_urls={
                "https://www.arrl.org/ares-el-old?issue=2006-12-20",
                "https://w2blc.net/nenets.htm",
                "https://groups.io/g/cvfma/topic/new_england_weather_net/74025849",
            },
            notes={
                "Commonly listed as 5:30-6:30 AM Eastern. Some directories shorten the end time or label it daily; Monday-Saturday is used here."
            },
            confidence="Verified fallback",
        )
    )


manifest_rows = []
if MANIFEST.exists():
    for raw_line in MANIFEST.read_text(encoding="utf-8", errors="replace").splitlines():
        fields = raw_line.split("\t")
        if len(fields) >= 4:
            manifest_rows.append(fields[:4])

all_entries: list[NetEntry] = []
source_summaries = []

for source_id, source_name, source_url, file_path in manifest_rows:
    path = Path(file_path)
    try:
        raw = path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        source_summaries.append((source_name, "Read failed", str(exc), source_url))
        continue

    table_parser = TableExtractor()
    text_parser = TextExtractor()
    try:
        table_parser.feed(raw)
        text_parser.feed(raw)
    except Exception as exc:
        source_summaries.append((source_name, "HTML parse warning", str(exc), source_url))

    page_entries: list[NetEntry] = []
    if source_id == "netlogger":
        page_entries.extend(parse_netlogger(table_parser.rows, source_id, source_name, source_url))
    else:
        page_entries.extend(parse_table_rows(table_parser.rows, source_id, source_name, source_url))

    # Use prose parsing when no useful table was found, or for known prose-heavy
    # directory pages. Avoid parsing clean table pages twice.
    prose_heavy = source_id in {"rac", "smarc", "midisland", "arrl"}
    if not page_entries or prose_heavy:
        page_entries.extend(parse_prose(text_parser.text(), source_id, source_name, source_url))

    all_entries.extend(page_entries)
    source_summaries.append(
        (source_name, "Parsed", f"{len(page_entries)} candidate listings", source_url)
    )

add_manual_verified_entries(all_entries)
entries = merge_entries(all_entries)

# Remove low-information false positives.
cleaned_entries = []
for entry in entries:
    if len(entry.name) > 160:
        continue
    if entry.frequency_mhz is None and entry.band == "Unknown":
        continue
    if entry.name.lower().startswith(("copyright", "website", "contact", "search")):
        continue
    cleaned_entries.append(entry)
entries = cleaned_entries

entries.sort(
    key=lambda x: (
        BAND_ORDER.get(x.band, 999),
        x.frequency_mhz if x.frequency_mhz is not None else 999999,
        normalize_time(x.time_raw)[2] if normalize_time(x.time_raw) else "99:99",
        x.name.lower(),
    )
)

by_band: dict[str, list[NetEntry]] = defaultdict(list)
for entry in entries:
    by_band[entry.band].append(entry)

source_status_text = ""
try:
    source_status_text = STATUS_FILE.read_text(encoding="utf-8", errors="replace")
except OSError:
    pass

successful_sources = sum(1 for line in source_status_text.splitlines() if line.startswith("OK\t"))
failed_sources = sum(1 for line in source_status_text.splitlines() if line.startswith("FAILED\t"))

# CSV
with CSV_REPORT.open("w", newline="", encoding="utf-8") as handle:
    writer = csv.writer(handle)
    writer.writerow([
        "Band", "Frequency", "Net Name", "Mode", "Days", "Listed Time",
        "Time Zone", "Upcoming Dates in Report Time Zone", "Confidence",
        "Notes", "Sources", "Source URLs",
    ])
    for entry in entries:
        writer.writerow([
            entry.band,
            entry.frequency_display,
            entry.name,
            entry.mode,
            entry.days_display,
            entry.time_raw or "Not stated",
            entry.timezone_label,
            entry.next_dates,
            entry.confidence,
            " | ".join(sorted(entry.notes)),
            " | ".join(sorted(entry.source_names)),
            " | ".join(sorted(entry.source_urls)),
        ])

# Plain-text report
text_lines = [
    "AMATEUR / HAM RADIO NET REPORT",
    "=" * 88,
    f"Generated: {GENERATED}",
    f"Report time zone: {REPORT_TZ_NAME}",
    f"Upcoming date window: {LOOKAHEAD_DAYS} days",
    f"Unique normalized listings: {len(entries)}",
    f"Sources successfully fetched: {successful_sources}",
    f"Sources unavailable: {failed_sources}",
    "",
    "IMPORTANT:",
    "No single public directory contains every amateur-radio net. Schedules can change,",
    "local club pages may not be indexed, and some public pages do not expose structured",
    "data. This report preserves source links and does not silently treat missing data as",
    "confirmed information.",
    "",
]

for band in sorted(by_band, key=lambda b: BAND_ORDER.get(b, 999)):
    band_entries = by_band[band]
    text_lines.extend([
        "",
        "#" * 88,
        f"{band.upper()}  ({len(band_entries)} listings)",
        "#" * 88,
    ])

    for entry in band_entries:
        text_lines.extend([
            "",
            entry.name,
            f"  Frequency: {entry.frequency_display}",
            f"  Mode: {entry.mode}",
            f"  Schedule: {entry.days_display}",
            f"  Listed time: {entry.listed_time_display}",
            f"  Upcoming in {REPORT_TZ_NAME}: {entry.next_dates}",
            f"  Status: {entry.confidence}",
            f"  Sources: {'; '.join(sorted(entry.source_names))}",
        ])
        if entry.notes:
            text_lines.append(f"  Notes: {'; '.join(sorted(entry.notes))}")
        for url in sorted(entry.source_urls):
            text_lines.append(f"  Source URL: {url}")

text_lines.extend([
    "",
    "=" * 88,
    "SOURCE FETCH STATUS",
    "=" * 88,
    source_status_text.strip() or "No source status information was recorded.",
    "",
])

TEXT_REPORT.write_text("\n".join(text_lines), encoding="utf-8")

# HTML report
def esc(value: object) -> str:
    return html.escape(str(value), quote=True)

sections = []
for band in sorted(by_band, key=lambda b: BAND_ORDER.get(b, 999)):
    rows_html = []
    for entry in by_band[band]:
        source_links = "<br>".join(
            f'<a href="{esc(url)}" target="_blank" rel="noopener">{esc(url)}</a>'
            for url in sorted(entry.source_urls)
        )
        notes = "<br>".join(esc(note) for note in sorted(entry.notes))
        rows_html.append(
            "<tr>"
            f"<td>{esc(entry.frequency_display)}</td>"
            f"<td><strong>{esc(entry.name)}</strong></td>"
            f"<td>{esc(entry.mode)}</td>"
            f"<td>{esc(entry.days_display)}</td>"
            f"<td>{esc(entry.listed_time_display)}</td>"
            f"<td>{esc(entry.next_dates)}</td>"
            f"<td>{esc(entry.confidence)}</td>"
            f"<td>{notes}</td>"
            f"<td>{source_links}</td>"
            "</tr>"
        )

    sections.append(
        f'<section class="band"><h2>{esc(band)} '
        f'<span>{len(by_band[band])} listings</span></h2>'
        '<div class="table-wrap"><table>'
        '<thead><tr>'
        '<th>Frequency</th><th>Net</th><th>Mode</th><th>Days</th>'
        '<th>Listed time</th><th>Upcoming dates</th><th>Status</th>'
        '<th>Notes</th><th>Sources</th>'
        '</tr></thead><tbody>'
        + "".join(rows_html)
        + "</tbody></table></div></section>"
    )

html_document = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Ham Radio Net Report</title>
<style>
:root {{
  color-scheme: light dark;
  --bg: #f4f6f8;
  --panel: #ffffff;
  --text: #17202a;
  --muted: #566573;
  --line: #cfd8dc;
  --heading: #17365d;
  --accent: #b51f2e;
}}
@media (prefers-color-scheme: dark) {{
  :root {{
    --bg: #11151a;
    --panel: #1b222a;
    --text: #ecf0f1;
    --muted: #b7c2cc;
    --line: #3b4652;
    --heading: #8db7e8;
    --accent: #ff7d89;
  }}
}}
* {{ box-sizing: border-box; }}
body {{
  margin: 0;
  background: var(--bg);
  color: var(--text);
  font-family: Arial, Helvetica, sans-serif;
  line-height: 1.4;
}}
header {{
  padding: 24px;
  background: #102a43;
  color: white;
}}
header h1 {{ margin: 0 0 8px; font-size: 1.8rem; }}
header p {{ margin: 4px 0; }}
main {{ max-width: 1800px; margin: 0 auto; padding: 18px; }}
.notice {{
  background: var(--panel);
  border-left: 5px solid var(--accent);
  padding: 14px 16px;
  margin-bottom: 18px;
}}
.controls {{
  display: flex;
  gap: 12px;
  flex-wrap: wrap;
  margin: 16px 0;
}}
input {{
  min-width: 320px;
  max-width: 100%;
  padding: 10px 12px;
  border: 1px solid var(--line);
  border-radius: 4px;
  background: var(--panel);
  color: var(--text);
}}
.band {{
  background: var(--panel);
  margin: 18px 0;
  border: 1px solid var(--line);
  border-radius: 6px;
  overflow: hidden;
}}
.band h2 {{
  margin: 0;
  padding: 12px 14px;
  color: var(--heading);
  border-bottom: 1px solid var(--line);
}}
.band h2 span {{
  float: right;
  color: var(--muted);
  font-size: .85rem;
  font-weight: normal;
}}
.table-wrap {{ overflow-x: auto; }}
table {{
  width: 100%;
  border-collapse: collapse;
  font-size: .9rem;
}}
th, td {{
  padding: 9px 10px;
  border-bottom: 1px solid var(--line);
  text-align: left;
  vertical-align: top;
}}
th {{
  position: sticky;
  top: 0;
  background: var(--panel);
}}
tr:hover {{ outline: 2px solid var(--line); }}
a {{ color: var(--heading); overflow-wrap: anywhere; }}
footer {{ padding: 20px; color: var(--muted); text-align: center; }}
.hidden {{ display: none; }}
</style>
</head>
<body>
<header>
  <h1>Amateur / Ham Radio Net Report</h1>
  <p>Generated {esc(GENERATED)}</p>
  <p>{len(entries)} normalized listings | Report time zone: {esc(REPORT_TZ_NAME)}</p>
</header>
<main>
  <div class="notice">
    <strong>Directory limitation:</strong> no public source contains every net.
    Listings may be stale or incomplete. Source links and conflicts are retained so
    schedules can be checked before transmitting.
  </div>
  <div class="controls">
    <input id="filter" type="search"
      placeholder="Filter by net, band, frequency, day, mode, or source">
  </div>
  {''.join(sections) if sections else '<p>No listings were parsed. Review source_status.txt.</p>'}
</main>
<footer>
  Generated by Ham Radio Net Aggregator
</footer>
<script>
const input = document.getElementById('filter');
input.addEventListener('input', () => {{
  const needle = input.value.toLowerCase().trim();
  document.querySelectorAll('tbody tr').forEach(row => {{
    row.classList.toggle('hidden', needle && !row.textContent.toLowerCase().includes(needle));
  }});
  document.querySelectorAll('section.band').forEach(section => {{
    const visible = [...section.querySelectorAll('tbody tr')]
      .some(row => !row.classList.contains('hidden'));
    section.classList.toggle('hidden', !visible);
  }});
}});
</script>
</body>
</html>
"""
HTML_REPORT.write_text(html_document, encoding="utf-8")

print(json.dumps({
    "entries": len(entries),
    "bands": len(by_band),
    "sources_ok": successful_sources,
    "sources_failed": failed_sources,
    "text": str(TEXT_REPORT),
    "csv": str(CSV_REPORT),
    "html": str(HTML_REPORT),
}))
PY

parser_rc=$?
if [[ $parser_rc -ne 0 ]]; then
    printf '\n\033[31mThe report processor failed.\033[0m\n' >&2
    printf 'Review: %s\n' "$STATUS_FILE" >&2
else
    printf '\n\033[1;32mReport complete.\033[0m\n'
    printf 'Text: %s\n' "$TEXT_REPORT"
    printf 'CSV:  %s\n' "$CSV_REPORT"
    printf 'HTML: %s\n' "$HTML_REPORT"
    printf 'Source status: %s\n\n' "$STATUS_FILE"

    if command -v less >/dev/null 2>&1 && [[ -t 1 ]]; then
        printf 'Opening the scrollable text report. Press q to return to this terminal.\n'
        sleep 1
        less -R "$TEXT_REPORT"
    else
        cat "$TEXT_REPORT"
    fi
fi

#if (( PAUSE_AT_END )) && [[ -t 0 ]]; then
#    printf '\nPress any key to close this terminal...'
#    IFS= read -r -n 1 -s
#    printf '\n'
#fi

exit "$parser_rc"
