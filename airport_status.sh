#!/bin/bash

# ============================================================
# U.S. MAJOR AIRPORT STATUS MONITOR
#
# Sources:
#   FAA NAS Status:
#   https://nasstatus.faa.gov/api/airport-status-information
#
#   NWS Aviation Weather Center:
#   https://aviationweather.gov/api/data/metar
#
# Displays:
#   - Airport closures
#   - Ground stops
#   - Ground delay programs
#   - Arrival delays
#   - Departure delays
#   - FAA delay reason
#   - Weather-related restrictions
#   - METAR flight category
#   - Visibility
#   - Wind / gusts
#   - Ceiling
#   - Current weather
#
# Requirements:
#   bash
#   curl
#   python3
#
# No API keys required.
# ============================================================

set -u

FAA_URL="https://nasstatus.faa.gov/api/airport-status-information"
AWC_URL="https://aviationweather.gov/api/data/metar"

TMPDIR="${TMPDIR:-/tmp}"
FAA_FILE="$TMPDIR/faa_airport_status_$$.xml"
WX_FILE="$TMPDIR/faa_airport_weather_$$.json"

# ------------------------------------------------------------
# TERMINAL COLORS
# ------------------------------------------------------------

RED='\033[1;31m'
YELLOW='\033[1;33m'
GREEN='\033[1;32m'
CYAN='\033[1;36m'
BLUE='\033[1;34m'
MAGENTA='\033[1;35m'
WHITE='\033[1;37m'
GRAY='\033[0;37m'
NC='\033[0m'

cleanup() {
    rm -f "$FAA_FILE" "$WX_FILE"
}

trap cleanup EXIT INT TERM

# ------------------------------------------------------------
# MAJOR U.S. AIRPORTS
#
# Format:
# FAA/IATA|ICAO|Airport name
#
# Add or remove airports here.
# ------------------------------------------------------------

AIRPORTS=$(cat <<'EOF'
ATL|KATL|Atlanta Hartsfield-Jackson
BOS|KBOS|Boston Logan
BWI|KBWI|Baltimore/Washington
CLT|KCLT|Charlotte Douglas
DCA|KDCA|Washington Reagan
DFW|KDFW|Dallas/Fort Worth
DEN|KDEN|Denver International
DTW|KDTW|Detroit Metro
EWR|KEWR|Newark Liberty
FLL|KFLL|Fort Lauderdale
IAD|KIAD|Washington Dulles
IAH|KIAH|Houston Intercontinental
JFK|KJFK|New York JFK
LGA|KLGA|New York LaGuardia
MCO|KMCO|Orlando International
MIA|KMIA|Miami International
MSP|KMSP|Minneapolis-St Paul
ORD|KORD|Chicago O'Hare
PHL|KPHL|Philadelphia International
RDU|KRDU|Raleigh-Durham
TPA|KTPA|Tampa International
CLE|KCLE|Cleveland Hopkins
CMH|KCMH|Columbus
CVG|KCVG|Cincinnati/Northern Kentucky
IND|KIND|Indianapolis
MCI|KMCI|Kansas City
MEM|KMEM|Memphis
BNA|KBNA|Nashville
PIT|KPIT|Pittsburgh
STL|KSTL|St Louis Lambert
MDW|KMDW|Chicago Midway
DAL|KDAL|Dallas Love Field
HOU|KHOU|Houston Hobby
AUS|KAUS|Austin-Bergstrom
SAT|KSAT|San Antonio
MSY|KMSY|New Orleans
JAX|KJAX|Jacksonville
RSW|KRSW|Southwest Florida
PBI|KPBI|Palm Beach
SLC|KSLC|Salt Lake City
PHX|KPHX|Phoenix Sky Harbor
LAS|KLAS|Las Vegas Harry Reid
LAX|KLAX|Los Angeles International
SAN|KSAN|San Diego International
SFO|KSFO|San Francisco International
SJC|KSJC|San Jose
OAK|KOAK|Oakland
SEA|KSEA|Seattle-Tacoma
PDX|KPDX|Portland International
SMF|KSMF|Sacramento
ONT|KONT|Ontario California
SNA|KSNA|Orange County John Wayne
ABQ|KABQ|Albuquerque
BOI|KBOI|Boise
GEG|KGEG|Spokane
OMA|KOMA|Omaha Eppley
OKC|KOKC|Oklahoma City
TUL|KTUL|Tulsa
BUF|KBUF|Buffalo Niagara
ROC|KROC|Rochester
SYR|KSYR|Syracuse
ALB|KALB|Albany
BDL|KBDL|Hartford Bradley
PWM|KPWM|Portland Maine
PVD|KPVD|Providence
CHS|KCHS|Charleston
SAV|KSAV|Savannah
RIC|KRIC|Richmond
ORF|KORF|Norfolk
GSO|KGSO|Greensboro
SDF|KSDF|Louisville
MKE|KMKE|Milwaukee
DSM|KDSM|Des Moines
EOF
)

# ------------------------------------------------------------
# CHECK REQUIREMENTS
# ------------------------------------------------------------

for cmd in curl python3; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo -e "${RED}ERROR:${NC} $cmd is not installed."
        echo
        echo "Install it with:"
        echo "  sudo apt install $cmd"
        exit 1
    fi
done

# ------------------------------------------------------------
# BUILD ICAO LIST FOR WEATHER QUERY
# ------------------------------------------------------------

ICAO_LIST=$(echo "$AIRPORTS" |
    cut -d'|' -f2 |
    paste -sd, -)

# ------------------------------------------------------------
# DOWNLOAD DATA
# ------------------------------------------------------------

clear

echo -e "${CYAN}============================================================${NC}"
echo -e "${WHITE}       U.S. MAJOR AIRPORT STATUS MONITOR${NC}"
echo -e "${CYAN}============================================================${NC}"
echo
echo "Retrieving FAA National Airspace System status..."
echo "Retrieving current aviation weather..."
echo

FAA_OK=1
WX_OK=1

curl \
    --silent \
    --show-error \
    --fail \
    --max-time 20 \
    --retry 2 \
    --retry-delay 2 \
    -A "US-Airport-Status-Monitor/1.0" \
    "$FAA_URL" \
    -o "$FAA_FILE" || FAA_OK=0

curl \
    --silent \
    --show-error \
    --fail \
    --max-time 30 \
    --retry 2 \
    --retry-delay 2 \
    -A "US-Airport-Status-Monitor/1.0" \
    --get \
    --data-urlencode "ids=$ICAO_LIST" \
    --data-urlencode "format=json" \
    "$AWC_URL" \
    -o "$WX_FILE" || WX_OK=0

if [ "$FAA_OK" -eq 0 ]; then
    echo -e "${RED}WARNING: FAA status feed could not be downloaded.${NC}"
    echo
    echo '<AIRPORT_STATUS_INFORMATION></AIRPORT_STATUS_INFORMATION>' > "$FAA_FILE"
fi

if [ "$WX_OK" -eq 0 ]; then
    echo -e "${YELLOW}WARNING: Aviation weather could not be downloaded.${NC}"
    echo
    echo '[]' > "$WX_FILE"
fi

# ------------------------------------------------------------
# PARSE AND DISPLAY
# ------------------------------------------------------------

AIRPORT_DATA="$AIRPORTS" python3 - "$FAA_FILE" "$WX_FILE" <<'PYTHON'
import sys
import os
import json
import re
import xml.etree.ElementTree as ET
from datetime import datetime, timezone

faa_file = sys.argv[1]
wx_file = sys.argv[2]

# ------------------------------------------------------------
# ANSI COLORS
# ------------------------------------------------------------

RED     = "\033[1;31m"
YELLOW  = "\033[1;33m"
GREEN   = "\033[1;32m"
CYAN    = "\033[1;36m"
BLUE    = "\033[1;34m"
MAGENTA = "\033[1;35m"
WHITE   = "\033[1;37m"
GRAY    = "\033[0;37m"
NC      = "\033[0m"

# ------------------------------------------------------------
# AIRPORT LIST
# ------------------------------------------------------------

airport_text = os.environ.get("AIRPORT_DATA", "")

airports = []

for line in airport_text.splitlines():
    line = line.strip()

    if not line or "|" not in line:
        continue

    parts = line.split("|", 2)

    if len(parts) == 3:
        airports.append({
            "faa": parts[0],
            "icao": parts[1],
            "name": parts[2]
        })

# ------------------------------------------------------------
# FAA XML
# ------------------------------------------------------------

faa_status = {}
faa_update = "Unknown"

def clean(text):
    if not text:
        return ""
    return " ".join(str(text).split())

try:
    tree = ET.parse(faa_file)
    root = tree.getroot()

    update = root.find("Update_Time")
    if update is not None and update.text:
        faa_update = clean(update.text)

    for delay_type in root.findall(".//Delay_type"):

        type_node = delay_type.find("Name")

        if type_node is None:
            continue

        delay_name = clean(type_node.text)

        # Look for any element containing an immediate ARPT child.
        # This makes the parser tolerant of FAA's different record
        # structures for Ground_Stop, Ground_Delay, Delay, Airport, etc.

        for elem in delay_type.iter():

            arpt_node = elem.find("ARPT")

            if arpt_node is None or not arpt_node.text:
                continue

            airport = clean(arpt_node.text).upper()

            fields = {}

            for child in elem.iter():

                if child is elem:
                    continue

                if len(child) == 0 and child.text:

                    tag = child.tag
                    value = clean(child.text)

                    if value and tag != "ARPT":
                        fields.setdefault(tag, value)

            faa_status.setdefault(airport, []).append({
                "type": delay_name,
                "fields": fields
            })

except Exception as exc:
    print(f"{RED}FAA XML parsing error: {exc}{NC}")

# Remove duplicate FAA records that can result from nested traversal.

for code in list(faa_status.keys()):

    seen = set()
    unique = []

    for event in faa_status[code]:

        key = (
            event["type"],
            tuple(sorted(event["fields"].items()))
        )

        if key not in seen:
            seen.add(key)
            unique.append(event)

    faa_status[code] = unique

# ------------------------------------------------------------
# WEATHER JSON
# ------------------------------------------------------------

weather = {}

try:
    with open(wx_file, "r", encoding="utf-8") as f:
        wx_data = json.load(f)

    if isinstance(wx_data, dict):
        wx_data = wx_data.get("data", [wx_data])

    if not isinstance(wx_data, list):
        wx_data = []

    for item in wx_data:

        if not isinstance(item, dict):
            continue

        icao = (
            item.get("icaoId")
            or item.get("icao")
            or item.get("stationId")
            or ""
        ).upper()

        if icao:
            weather[icao] = item

except Exception as exc:
    print(f"{YELLOW}Weather JSON parsing error: {exc}{NC}")

# ------------------------------------------------------------
# WEATHER HELPERS
# ------------------------------------------------------------

def value(item, *keys):
    for key in keys:
        if key in item and item[key] not in (None, ""):
            return item[key]
    return None

def flight_category(item):

    cat = value(
        item,
        "fltCat",
        "flight_category",
        "flightCategory"
    )

    if cat:
        return str(cat).upper()

    return "N/A"

def category_color(cat):

    cat = cat.upper()

    if cat == "VFR":
        return GREEN
    if cat == "MVFR":
        return BLUE
    if cat == "IFR":
        return RED
    if cat == "LIFR":
        return MAGENTA

    return GRAY

def weather_description(item):

    wx = value(
        item,
        "wxString",
        "wx",
        "weather"
    )

    if not wx:
        return "None"

    return str(wx)

def visibility(item):

    vis = value(item, "visib", "visibility")

    if vis is None:
        return "N/A"

    try:
        return f"{float(vis):g} mi"
    except:
        return str(vis)

def wind(item):

    direction = value(item, "wdir", "windDir")
    speed = value(item, "wspd", "windSpeed")
    gust = value(item, "wgst", "windGust")

    if speed is None:
        return "N/A"

    try:
        speed_text = str(int(float(speed)))
    except:
        speed_text = str(speed)

    if direction in (None, ""):
        direction_text = "VAR"
    else:
        try:
            direction_text = f"{int(float(direction)):03d}"
        except:
            direction_text = str(direction)

    result = f"{direction_text}/{speed_text}kt"

    if gust not in (None, "", 0, "0"):
        try:
            result += f" G{int(float(gust))}kt"
        except:
            result += f" G{gust}kt"

    return result

def ceiling(item):

    clouds = item.get("clouds")

    if isinstance(clouds, list):

        ceilings = []

        for cloud in clouds:

            if not isinstance(cloud, dict):
                continue

            cover = str(
                cloud.get("cover", "")
            ).upper()

            base = cloud.get("base")

            if cover in ("BKN", "OVC", "VV") and base is not None:

                try:
                    ceilings.append(
                        (int(float(base)), cover)
                    )
                except:
                    pass

        if ceilings:

            ceilings.sort()

            altitude, cover = ceilings[0]

            return f"{cover} {altitude:,} ft"

    cover = value(item, "cover")
    base = value(item, "cloudBase")

    if cover and base:
        return f"{cover} {base} ft"

    return "N/A"

# ------------------------------------------------------------
# FAA STATUS HELPERS
# ------------------------------------------------------------

def event_severity(events):

    combined = " ".join(
        event["type"].lower()
        for event in events
    )

    if "closure" in combined:
        return 5

    if "ground stop" in combined:
        return 5

    if "ground delay" in combined:
        return 4

    if "arrival" in combined or "departure" in combined:
        return 3

    return 2

def status_label(events):

    if not events:
        return "NORMAL"

    types = [e["type"].lower() for e in events]

    if any("closure" in x for x in types):
        return "CLOSED"

    if any("ground stop" in x for x in types):
        return "GROUND STOP"

    if any("ground delay" in x for x in types):
        return "GROUND DELAY"

    if any(
        "arrival" in x or "departure" in x
        for x in types
    ):
        return "A/D DELAY"

    return "RESTRICTION"

def status_color(label):

    if label in ("CLOSED", "GROUND STOP"):
        return RED

    if label in ("GROUND DELAY", "A/D DELAY", "RESTRICTION"):
        return YELLOW

    return GREEN

def is_weather_related(events):

    search = ""

    for event in events:
        search += " " + event["type"]

        for v in event["fields"].values():
            search += " " + str(v)

    search = search.lower()

    weather_words = [
        "weather",
        " wx",
        "thunder",
        "storm",
        "snow",
        "ice",
        "icing",
        "wind",
        "fog",
        "ceiling",
        "visibility",
        "rain",
        "tornado",
        "hurricane"
    ]

    return any(word in search for word in weather_words)

def event_details(event):

    fields = event["fields"]

    parts = []

    preferred = [
        "Reason",
        "Avg",
        "Max",
        "Min",
        "Trend",
        "Start",
        "End_Time",
        "End",
        "Reopen",
        "Update",
        "POE",
        "Scope"
    ]

    used = set()

    for key in preferred:

        if key in fields:
            parts.append(f"{key}: {fields[key]}")
            used.add(key)

    for key, val in fields.items():

        if key not in used:
            parts.append(f"{key}: {val}")

    return " | ".join(parts)

# ------------------------------------------------------------
# HEADER
# ------------------------------------------------------------

now = datetime.now().astimezone()

print()
print(f"{CYAN}{'=' * 118}{NC}")
print(f"{WHITE}U.S. MAJOR AIRPORT STATUS{NC}")
print(f"Local time: {now.strftime('%Y-%m-%d %H:%M:%S %Z')}")
print(f"FAA feed : {faa_update}")
print(f"{CYAN}{'=' * 118}{NC}")
print()

print(
    f"{'CODE':<5} "
    f"{'AIRPORT':<31} "
    f"{'FAA STATUS':<15} "
    f"{'FLT':<6} "
    f"{'VIS':<8} "
    f"{'WIND':<17} "
    f"{'CEILING':<16} "
    f"WEATHER"
)

print("-" * 118)

# ------------------------------------------------------------
# MAIN AIRPORT TABLE
# ------------------------------------------------------------

active_airports = []

for airport in airports:

    code = airport["faa"]
    icao = airport["icao"]
    name = airport["name"]

    events = faa_status.get(code, [])

    label = status_label(events)

    if events:
        active_airports.append((airport, events))

    wx = weather.get(icao, {})

    cat = flight_category(wx)
    vis = visibility(wx)
    wnd = wind(wx)
    ceil = ceiling(wx)
    wxdesc = weather_description(wx)

    scolor = status_color(label)
    ccolor = category_color(cat)

    weather_mark = ""

    if is_weather_related(events):
        weather_mark = " [FAA WX]"

    print(
        f"{code:<5} "
        f"{name[:30]:<31} "
        f"{scolor}{label:<15}{NC} "
        f"{ccolor}{cat:<6}{NC} "
        f"{vis:<8} "
        f"{wnd:<17} "
        f"{ceil:<16} "
        f"{wxdesc}{weather_mark}"
    )

# ------------------------------------------------------------
# ACTIVE FAA RESTRICTIONS
# ------------------------------------------------------------

print()
print(f"{CYAN}{'=' * 118}{NC}")
print(f"{WHITE}ACTIVE FAA DELAYS / RESTRICTIONS{NC}")
print(f"{CYAN}{'=' * 118}{NC}")

if not active_airports:

    print()
    print(f"{GREEN}No FAA restrictions are currently reported for the monitored major airports.{NC}")

else:

    active_airports.sort(
        key=lambda x: event_severity(x[1]),
        reverse=True
    )

    for airport, events in active_airports:

        code = airport["faa"]
        name = airport["name"]

        label = status_label(events)
        color = status_color(label)

        print()
        print(
            f"{color}{code} - {name} : {label}{NC}"
        )

        for event in events:

            print(
                f"  {YELLOW}{event['type']}{NC}"
            )

            details = event_details(event)

            if details:
                print(f"    {details}")

# ------------------------------------------------------------
# SIGNIFICANT WEATHER
# ------------------------------------------------------------

print()
print(f"{CYAN}{'=' * 118}{NC}")
print(f"{WHITE}SIGNIFICANT AIRPORT WEATHER CONDITIONS{NC}")
print(f"{CYAN}{'=' * 118}{NC}")
print()

significant = []

for airport in airports:

    wx = weather.get(airport["icao"], {})

    if not wx:
        continue

    cat = flight_category(wx)

    gust = value(wx, "wgst", "windGust")
    vis = value(wx, "visib", "visibility")
    wxdesc = weather_description(wx)

    bad = False

    if cat in ("IFR", "LIFR"):
        bad = True

    try:
        if gust is not None and float(gust) >= 30:
            bad = True
    except:
        pass

    try:
        if vis is not None and float(vis) < 3:
            bad = True
    except:
        pass

    wx_upper = wxdesc.upper()

    significant_codes = [
        "TS",
        "FZ",
        "SN",
        "FG",
        "SQ",
        "GR",
        "+RA"
    ]

    if any(x in wx_upper for x in significant_codes):
        bad = True

    if bad:
        significant.append((airport, wx))

if not significant:

    print(f"{GREEN}No major IFR/LIFR or severe weather conditions detected at monitored airports.{NC}")

else:

    for airport, wx in significant:

        cat = flight_category(wx)

        print(
            f"{category_color(cat)}"
            f"{airport['faa']:<4} "
            f"{airport['name']:<31} "
            f"{cat:<5}"
            f"{NC} "
            f"VIS {visibility(wx):<8} "
            f"WIND {wind(wx):<17} "
            f"CEILING {ceiling(wx):<16} "
            f"{weather_description(wx)}"
        )

# ------------------------------------------------------------
# LEGEND
# ------------------------------------------------------------

print()
print(f"{CYAN}{'=' * 118}{NC}")
print(f"{WHITE}LEGEND{NC}")
print(f"{CYAN}{'=' * 118}{NC}")

print(
    f"{GREEN}NORMAL{NC}       No FAA delay program reported"
)

print(
    f"{YELLOW}GROUND DELAY{NC} FAA Ground Delay Program active"
)

print(
    f"{RED}GROUND STOP{NC}  FAA Ground Stop active"
)

print(
    f"{RED}CLOSED{NC}       Airport closure reported"
)

print()
print(
    f"Flight category: "
    f"{GREEN}VFR{NC}  "
    f"{BLUE}MVFR{NC}  "
    f"{RED}IFR{NC}  "
    f"{MAGENTA}LIFR{NC}"
)

print()
print(
    "FAA information is airport/system status, not individual flight status."
)

print(
    "Check the airline for the status of a specific flight."
)

print()

PYTHON

# ------------------------------------------------------------
# REPEAT OR EXIT
# ------------------------------------------------------------

echo
echo -e "${CYAN}============================================================${NC}"
echo
read -r -p "Press R to refresh, or ENTER to close: " ANSWER

if [[ "$ANSWER" =~ ^[Rr]$ ]]; then
    exec "$0"
fi

exit 0
