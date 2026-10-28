
#!/bin/bash

# ==============================================================
# U.S. MAJOR AIRPORT STATUS MONITOR
#
# Sources:
#   FAA NAS Status:
#   https://nasstatus.faa.gov/api/airport-status-information
#
#   Aviation Weather Center METAR API:
#   https://aviationweather.gov/api/data/metar
#
# Requirements:
#   curl
#   python3
#
# Run:
#   chmod +x airport_status.sh
#   ./airport_status.sh
# ==============================================================

set -u

FAA_URL="https://nasstatus.faa.gov/api/airport-status-information"
METAR_URL="https://aviationweather.gov/api/data/metar"

TMPDIR="$(mktemp -d)"
FAA_XML="$TMPDIR/faa_status.xml"
METAR_JSON="$TMPDIR/metars.json"
AIRPORT_FILE="$TMPDIR/airports.txt"

trap 'rm -rf "$TMPDIR"' EXIT

# --------------------------------------------------------------
# COLORS
# --------------------------------------------------------------

RED='\033[1;31m'
YELLOW='\033[1;33m'
GREEN='\033[1;32m'
CYAN='\033[1;36m'
BLUE='\033[1;34m'
MAGENTA='\033[1;35m'
WHITE='\033[1;37m'
GRAY='\033[0;37m'
RESET='\033[0m'

# --------------------------------------------------------------
# MAJOR U.S. AIRPORTS
#
# Format:
# IATA|ICAO|CITY / AIRPORT
#
# Add or remove airports here as desired.
# --------------------------------------------------------------

cat > "$AIRPORT_FILE" <<'EOF'
ABQ|KABQ|Albuquerque, NM
ANC|PANC|Anchorage, AK
ATL|KATL|Atlanta, GA
AUS|KAUS|Austin, TX
BDL|KBDL|Hartford, CT
BNA|KBNA|Nashville, TN
BOS|KBOS|Boston, MA
BUF|KBUF|Buffalo, NY
BUR|KBUR|Burbank, CA
BWI|KBWI|Baltimore, MD
CHS|KCHS|Charleston, SC
CLE|KCLE|Cleveland, OH
CLT|KCLT|Charlotte, NC
CMH|KCMH|Columbus, OH
CVG|KCVG|Cincinnati, OH
DAL|KDAL|Dallas Love Field, TX
DCA|KDCA|Washington National, DC
DEN|KDEN|Denver, CO
DFW|KDFW|Dallas/Fort Worth, TX
DSM|KDSM|Des Moines, IA
DTW|KDTW|Detroit, MI
ELP|KELP|El Paso, TX
EWR|KEWR|Newark, NJ
FLL|KFLL|Fort Lauderdale, FL
GEG|KGEG|Spokane, WA
HNL|PHNL|Honolulu, HI
HOU|KHOU|Houston Hobby, TX
IAD|KIAD|Washington Dulles, VA
IAH|KIAH|Houston Intercontinental, TX
IND|KIND|Indianapolis, IN
JAX|KJAX|Jacksonville, FL
JFK|KJFK|New York JFK, NY
LAS|KLAS|Las Vegas, NV
LAX|KLAX|Los Angeles, CA
LGA|KLGA|New York LaGuardia, NY
LGB|KLGB|Long Beach, CA
LIH|PHLI|Lihue, HI
MCI|KMCI|Kansas City, MO
MCO|KMCO|Orlando, FL
MDW|KMDW|Chicago Midway, IL
MEM|KMEM|Memphis, TN
MIA|KMIA|Miami, FL
MKE|KMKE|Milwaukee, WI
MSP|KMSP|Minneapolis/St. Paul, MN
MSY|KMSY|New Orleans, LA
OAK|KOAK|Oakland, CA
OGG|PHOG|Kahului, HI
OKC|KOKC|Oklahoma City, OK
OMA|KOMA|Omaha, NE
ONT|KONT|Ontario, CA
ORD|KORD|Chicago O'Hare, IL
PBI|KPBI|West Palm Beach, FL
PDX|KPDX|Portland, OR
PHL|KPHL|Philadelphia, PA
PHX|KPHX|Phoenix, AZ
PIT|KPIT|Pittsburgh, PA
PVD|KPVD|Providence, RI
RDU|KRDU|Raleigh/Durham, NC
RIC|KRIC|Richmond, VA
RNO|KRNO|Reno, NV
RSW|KRSW|Fort Myers, FL
SAN|KSAN|San Diego, CA
SAT|KSAT|San Antonio, TX
SAV|KSAV|Savannah, GA
SEA|KSEA|Seattle, WA
SFO|KSFO|San Francisco, CA
SJC|KSJC|San Jose, CA
SJU|TJSJ|San Juan, PR
SLC|KSLC|Salt Lake City, UT
SMF|KSMF|Sacramento, CA
SNA|KSNA|Orange County, CA
STL|KSTL|St. Louis, MO
TEB|KTEB|Teterboro, NJ
TPA|KTPA|Tampa, FL
TUS|KTUS|Tucson, AZ
EOF


# --------------------------------------------------------------
# HEADER
# --------------------------------------------------------------

clear

echo -e "${CYAN}================================================================================================================${RESET}"
echo -e "${WHITE}                                      U.S. MAJOR AIRPORT STATUS${RESET}"
echo -e "${CYAN}================================================================================================================${RESET}"
echo
echo -e "Local Time : ${WHITE}$(date '+%A, %B %d, %Y  %I:%M:%S %p %Z')${RESET}"
echo -e "UTC Time   : ${WHITE}$(date -u '+%A, %B %d, %Y  %H:%M:%S UTC')${RESET}"
echo
echo "Downloading FAA traffic management data..."


# --------------------------------------------------------------
# DOWNLOAD FAA DATA
# --------------------------------------------------------------

if ! curl \
    --silent \
    --show-error \
    --fail \
    --location \
    --connect-timeout 10 \
    --max-time 30 \
    --user-agent "AirportStatusMonitor/1.0" \
    "$FAA_URL" \
    -o "$FAA_XML"
then
    echo -e "${RED}WARNING: Unable to retrieve FAA NAS status information.${RESET}"
    echo '<AIRPORT_STATUS_INFORMATION></AIRPORT_STATUS_INFORMATION>' > "$FAA_XML"
fi


# --------------------------------------------------------------
# BUILD LIST OF ICAO CODES
# --------------------------------------------------------------

ICAO_LIST=$(
    cut -d'|' -f2 "$AIRPORT_FILE" |
    paste -sd, -
)


# --------------------------------------------------------------
# DOWNLOAD CURRENT METARS
# --------------------------------------------------------------

echo "Downloading current aviation weather..."

if ! curl \
    --silent \
    --show-error \
    --fail \
    --location \
    --connect-timeout 10 \
    --max-time 30 \
    --user-agent "AirportStatusMonitor/1.0" \
    --get \
    --data-urlencode "ids=$ICAO_LIST" \
    --data-urlencode "format=json" \
    "$METAR_URL" \
    -o "$METAR_JSON"
then
    echo -e "${YELLOW}WARNING: Unable to retrieve Aviation Weather Center METAR data.${RESET}"
    echo '[]' > "$METAR_JSON"
fi

echo


# --------------------------------------------------------------
# PROCESS EVERYTHING WITH PYTHON
# --------------------------------------------------------------

python3 - "$FAA_XML" "$METAR_JSON" "$AIRPORT_FILE" <<'PYTHON'
import sys
import json
import re
import xml.etree.ElementTree as ET
from collections import defaultdict


faa_file = sys.argv[1]
metar_file = sys.argv[2]
airport_file = sys.argv[3]


# --------------------------------------------------------------
# ANSI COLORS
# --------------------------------------------------------------

RED     = "\033[1;31m"
YELLOW  = "\033[1;33m"
GREEN   = "\033[1;32m"
CYAN    = "\033[1;36m"
BLUE    = "\033[1;34m"
MAGENTA = "\033[1;35m"
WHITE   = "\033[1;37m"
GRAY    = "\033[0;37m"
RESET   = "\033[0m"


# --------------------------------------------------------------
# AIRPORT LIST
# --------------------------------------------------------------

airports = []

with open(airport_file, encoding="utf-8") as f:
    for line in f:
        line = line.strip()

        if not line or line.startswith("#"):
            continue

        parts = line.split("|", 2)

        if len(parts) == 3:
            airports.append({
                "iata": parts[0],
                "icao": parts[1],
                "name": parts[2]
            })


iata_set = {x["iata"] for x in airports}
icao_to_iata = {x["icao"]: x["iata"] for x in airports}


# --------------------------------------------------------------
# HELPER FUNCTIONS
# --------------------------------------------------------------

def clean(value):
    if value is None:
        return ""

    value = str(value)
    value = re.sub(r"\s+", " ", value)
    return value.strip()


def pretty_tag(tag):
    tag = tag.replace("_", " ")
    return tag.title()


def leaf_values(element):

    values = []

    for child in element.iter():

        if len(list(child)) == 0:

            text = clean(child.text)

            if text:
                values.append(
                    (child.tag, text)
                )

    return values


def airport_code(element):

    for child in element.iter():

        if child.tag.upper() == "ARPT":
            text = clean(child.text)

            if text:
                return text.upper()

    return None


def summarize_element(element):

    ignore = {
        "ARPT",
        "Airport",
        "Latitude",
        "Longitude"
    }

    values = []

    seen = set()

    for tag, text in leaf_values(element):

        if tag in ignore:
            continue

        item = f"{pretty_tag(tag)}: {text}"

        if item not in seen:
            values.append(item)
            seen.add(item)

    return " | ".join(values)


# --------------------------------------------------------------
# FAA DATA
# --------------------------------------------------------------

faa_status = defaultdict(list)
national_programs = []
faa_update = "Unknown"


try:

    tree = ET.parse(faa_file)
    root = tree.getroot()

    update_node = root.find(".//Update_Time")

    if update_node is not None and update_node.text:
        faa_update = clean(update_node.text)

    for delay_type in root.findall(".//Delay_type"):

        name_node = delay_type.find("Name")

        delay_name = (
            clean(name_node.text)
            if name_node is not None
            else "FAA Restriction"
        )

        # ------------------------------------------------------
        # Search each list contained in this Delay_type.
        # ------------------------------------------------------

        found_airport_entry = False

        for container in list(delay_type):

            if container.tag == "Name":
                continue

            children = list(container)

            if not children:
                continue

            for entry in children:

                arpt = airport_code(entry)

                if arpt:

                    found_airport_entry = True

                    description = summarize_element(entry)

                    faa_status[arpt].append({
                        "type": delay_name,
                        "description": description
                    })

                else:

                    # National or airspace-based traffic program.
                    desc = summarize_element(entry)

                    if desc:

                        national_programs.append({
                            "type": delay_name,
                            "description": desc
                        })

except Exception as exc:

    faa_update = "FAA feed unavailable"


# --------------------------------------------------------------
# METAR DATA
# --------------------------------------------------------------

weather = {}


try:

    with open(metar_file, encoding="utf-8") as f:
        raw = f.read().strip()

    if raw:
        metars = json.loads(raw)
    else:
        metars = []

    if isinstance(metars, dict):

        # Handle APIs which wrap the observations in an object.

        for possible in ("data", "features", "results"):

            if possible in metars and isinstance(metars[possible], list):
                metars = metars[possible]
                break

    if not isinstance(metars, list):
        metars = []

    for item in metars:

        if not isinstance(item, dict):
            continue

        # GeoJSON-compatible fallback
        if "properties" in item and isinstance(item["properties"], dict):
            record = item["properties"]
        else:
            record = item

        icao = clean(
            record.get("icaoId")
            or record.get("station")
            or record.get("station_id")
            or record.get("id")
        ).upper()

        if not icao:
            continue

        weather[icao] = record

except Exception:
    weather = {}


# --------------------------------------------------------------
# WEATHER FORMATTERS
# --------------------------------------------------------------

def wx_value(record, *names):

    for name in names:

        value = record.get(name)

        if value is not None and value != "":
            return value

    return None


def flight_category(record):

    cat = wx_value(
        record,
        "fltCat",
        "flightCategory",
        "flight_category"
    )

    if cat:
        return str(cat).upper()

    return "N/A"


def visibility(record):

    vis = wx_value(
        record,
        "visib",
        "visibility"
    )

    if vis is None:
        return "N/A"

    return f"{vis} SM"


def wind(record):

    direction = wx_value(
        record,
        "wdir",
        "windDir"
    )

    speed = wx_value(
        record,
        "wspd",
        "windSpeed"
    )

    gust = wx_value(
        record,
        "wgst",
        "windGust"
    )

    if direction is None and speed is None:
        return "N/A"

    if str(direction).upper() in ("VRB", "VARIABLE"):
        text = "VRB"
    elif direction is not None:
        try:
            text = f"{int(float(direction)):03d}"
        except Exception:
            text = str(direction)
    else:
        text = "---"

    if speed is not None:
        try:
            text += f"/{int(float(speed))}kt"
        except Exception:
            text += f"/{speed}kt"

    if gust is not None:
        try:
            text += f" G{int(float(gust))}"
        except Exception:
            text += f" G{gust}"

    return text


def raw_metar(record):

    return clean(
        wx_value(
            record,
            "rawOb",
            "raw_text",
            "raw"
        )
    )


def category_color(category):

    category = category.upper()

    if category == "VFR":
        return GREEN

    if category == "MVFR":
        return BLUE

    if category == "IFR":
        return RED

    if category == "LIFR":
        return MAGENTA

    return GRAY


# --------------------------------------------------------------
# DETERMINE FAA SEVERITY
# --------------------------------------------------------------

def status_color(entries):

    text = " ".join(
        (
            e["type"] + " " + e["description"]
        ).lower()
        for e in entries
    )

    if "closure" in text or "closed" in text:
        return RED

    if "ground stop" in text:
        return RED

    if "ground delay" in text:
        return YELLOW

    if "delay" in text:
        return YELLOW

    if "ctop" in text:
        return YELLOW

    if "airspace flow" in text:
        return YELLOW

    return CYAN


def status_label(entries):

    if not entries:
        return "NORMAL"

    text = " ".join(
        e["type"].lower()
        for e in entries
    )

    if "airport closure" in text:
        return "CLOSURE"

    if "ground stop" in text:
        return "GROUND STOP"

    if "ground delay" in text:
        return "GROUND DELAY"

    if "arrival" in text or "departure" in text:
        return "ARR/DEP DELAY"

    if "ctop" in text:
        return "CTOP"

    if "airspace" in text:
        return "AIRSPACE"

    return "RESTRICTION"


# --------------------------------------------------------------
# FAA UPDATE INFORMATION
# --------------------------------------------------------------

print("=" * 116)
print("FAA NATIONAL AIRSPACE SYSTEM STATUS")
print("=" * 116)

print(f"FAA feed last updated: {faa_update}")
print()


# --------------------------------------------------------------
# ACTIVE AIRPORT RESTRICTIONS
# --------------------------------------------------------------

active_major = []

for airport in airports:

    entries = faa_status.get(airport["iata"], [])

    if entries:
        active_major.append(
            (airport, entries)
        )


print("=" * 116)
print("ACTIVE RESTRICTIONS AT MAJOR AIRPORTS")
print("=" * 116)

if not active_major:

    print(
        GREEN
        + "No FAA ground stops, ground delay programs, closures, "
          "or reportable arrival/departure delays are currently "
          "listed for the airports monitored."
        + RESET
    )

else:

    for airport, entries in active_major:

        color = status_color(entries)
        label = status_label(entries)

        print()
        print(
            f"{color}{airport['iata']:<4} "
            f"{label:<16}{RESET} "
            f"{airport['name']}"
        )

        for entry in entries:

            print(
                f"     {entry['type']}: "
                f"{entry['description']}"
            )

print()


# --------------------------------------------------------------
# NATIONAL / AIRSPACE PROGRAMS
# --------------------------------------------------------------

if national_programs:

    print("=" * 116)
    print("OTHER NATIONAL / AIRSPACE TRAFFIC MANAGEMENT INITIATIVES")
    print("=" * 116)

    unique = set()

    for program in national_programs:

        key = (
            program["type"],
            program["description"]
        )

        if key in unique:
            continue

        unique.add(key)

        print()
        print(
            f"{YELLOW}{program['type']}{RESET}"
        )

        print(
            f"     {program['description']}"
        )

    print()


# --------------------------------------------------------------
# COMPLETE AIRPORT LIST
# --------------------------------------------------------------

print("=" * 116)
print("ALL MONITORED MAJOR U.S. AIRPORTS")
print("=" * 116)

header = (
    f"{'ARPT':<5}"
    f"{'LOCATION':<30}"
    f"{'FAA STATUS':<18}"
    f"{'WX':<7}"
    f"{'VIS':<10}"
    f"{'WIND':<17}"
)

print(header)
print("-" * 116)


for airport in airports:

    iata = airport["iata"]
    icao = airport["icao"]
    name = airport["name"]

    entries = faa_status.get(iata, [])

    if entries:

        faa_label = status_label(entries)
        faa_color = status_color(entries)

    else:

        faa_label = "NORMAL"
        faa_color = GREEN


    record = weather.get(icao, {})

    if record:

        cat = flight_category(record)
        vis = visibility(record)
        wnd = wind(record)

    else:

        cat = "N/A"
        vis = "N/A"
        wnd = "N/A"


    wx_color = category_color(cat)

    # Strip long airport name if needed for terminal table
    display_name = name[:28]

    print(
        f"{WHITE}{iata:<5}{RESET}"
        f"{display_name:<30}"
        f"{faa_color}{faa_label:<18}{RESET}"
        f"{wx_color}{cat:<7}{RESET}"
        f"{vis:<10}"
        f"{wnd:<17}"
    )


# --------------------------------------------------------------
# RESTRICTION DETAILS
# --------------------------------------------------------------

if active_major:

    print()
    print("=" * 116)
    print("DETAILED DELAY / RESTRICTION INFORMATION")
    print("=" * 116)

    for airport, entries in active_major:

        print()
        print(
            f"{WHITE}{airport['iata']} - "
            f"{airport['name']}{RESET}"
        )

        for entry in entries:

            print(
                f"  {entry['type']}"
            )

            if entry["description"]:
                print(
                    f"    {entry['description']}"
                )


# --------------------------------------------------------------
# SIGNIFICANT WEATHER
# --------------------------------------------------------------

bad_weather = []

for airport in airports:

    record = weather.get(airport["icao"], {})

    if not record:
        continue

    cat = flight_category(record)

    if cat in ("MVFR", "IFR", "LIFR"):
        bad_weather.append(
            (
                airport,
                cat,
                visibility(record),
                wind(record),
                raw_metar(record)
            )
        )


print()
print("=" * 116)
print("SIGNIFICANT AIRPORT WEATHER")
print("=" * 116)

if not bad_weather:

    print(
        GREEN
        + "No MVFR, IFR, or LIFR conditions detected at monitored airports."
        + RESET
    )

else:

    severity = {
        "LIFR": 0,
        "IFR": 1,
        "MVFR": 2
    }

    bad_weather.sort(
        key=lambda x: severity.get(x[1], 99)
    )

    for airport, cat, vis, wnd, metar in bad_weather:

        color = category_color(cat)

        print()
        print(
            f"{color}{airport['iata']}  {cat}{RESET}"
            f"  {airport['name']}"
        )

        print(
            f"     Visibility: {vis}"
        )

        print(
            f"     Wind:       {wnd}"
        )

        if metar:
            print(
                f"     METAR:      {metar}"
            )


# --------------------------------------------------------------
# LEGEND
# --------------------------------------------------------------

print()
print("=" * 116)
print("LEGEND")
print("=" * 116)

print(
    f"{GREEN}NORMAL{RESET}       "
    "No active FAA restriction in the national status feed."
)

print(
    f"{YELLOW}GROUND DELAY{RESET} "
    "FAA Ground Delay Program or reportable airport delay."
)

print(
    f"{RED}GROUND STOP{RESET}  "
    "FAA Ground Stop currently listed."
)

print(
    f"{RED}CLOSURE{RESET}      "
    "FAA feed lists an airport closure."
)

print()

print(
    f"{GREEN}VFR{RESET}   Visual Flight Rules"
)

print(
    f"{BLUE}MVFR{RESET}  Marginal Visual Flight Rules"
)

print(
    f"{RED}IFR{RESET}   Instrument Flight Rules"
)

print(
    f"{MAGENTA}LIFR{RESET}  Low Instrument Flight Rules"
)

print()
print(
    "FAA status is airport/NAS-wide information and is not "
    "specific to an individual airline flight."
)

print(
    "Check the airline for individual flight delays, cancellations, "
    "gate changes, or schedule changes."
)

print()
print("=" * 116)

PYTHON


# --------------------------------------------------------------
# END
# --------------------------------------------------------------

echo
read -rp "Press ENTER to close..."