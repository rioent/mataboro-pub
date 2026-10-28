#!/bin/bash

# ============================================================
# U.S. MAJOR AIRPORT STATUS - HTML GENERATOR
#
# Creates:
#   ~/Desktop/airport_status.html
#
# Display order:
#   1. Summary counters
#   2. Active FAA delays and restrictions
#   3. Significant airport weather
#   4. Full monitored airport list
#
# Header displays:
#   Local time
#   UTC time
#   FAA feed update time
#
# Data sources:
#   FAA NAS Status
#   Aviation Weather Center METAR API
#
# Requirements:
#   curl
#   python3
# ============================================================

set -u

FAA_URL="https://nasstatus.faa.gov/api/airport-status-information"
AWC_URL="https://aviationweather.gov/api/data/metar"

OUTPUT_FILE="$HOME/Desktop/airport_status.html"

TMPDIR="${TMPDIR:-/tmp}"
FAA_FILE="$TMPDIR/faa_airport_status_$$.xml"
WX_FILE="$TMPDIR/faa_airport_weather_$$.json"

cleanup() {
    rm -f "$FAA_FILE" "$WX_FILE"
}

trap cleanup EXIT INT TERM


# ============================================================
# MAJOR U.S. AIRPORTS
#
# Format:
# IATA|ICAO|Airport Name
# ============================================================

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
HPN|KHPN|Westchester County
SWF|KSWF|New York Stewart
ABE|KABE|Lehigh Valley
AVP|KAVP|Wilkes-Barre/Scranton
ACY|KACY|Atlantic City
EOF
)


# ============================================================
# CHECK REQUIREMENTS
# ============================================================

for cmd in curl python3; do

    if ! command -v "$cmd" >/dev/null 2>&1; then

        echo "ERROR: $cmd is not installed."
        echo
        echo "Linux Mint / Ubuntu:"
        echo "sudo apt install $cmd"

        exit 1

    fi

done


# ============================================================
# BUILD ICAO QUERY LIST
# ============================================================

ICAO_LIST=$(echo "$AIRPORTS" | cut -d'|' -f2 | paste -sd, -)


clear

echo "============================================================"
echo " U.S. MAJOR AIRPORT STATUS"
echo "============================================================"
echo
echo "Downloading FAA airport status..."


FAA_OK=1
WX_OK=1


curl \
    --silent \
    --show-error \
    --fail \
    --max-time 25 \
    --retry 2 \
    --retry-delay 2 \
    -A "US-Airport-Status-HTML/1.0" \
    "$FAA_URL" \
    -o "$FAA_FILE" || FAA_OK=0


echo "Downloading current airport weather..."


curl \
    --silent \
    --show-error \
    --fail \
    --max-time 30 \
    --retry 2 \
    --retry-delay 2 \
    -A "US-Airport-Status-HTML/1.0" \
    --get \
    --data-urlencode "ids=$ICAO_LIST" \
    --data-urlencode "format=json" \
    "$AWC_URL" \
    -o "$WX_FILE" || WX_OK=0


if [ "$FAA_OK" -eq 0 ]; then

    echo
    echo "WARNING: FAA data could not be downloaded."

    echo \
    '<AIRPORT_STATUS_INFORMATION></AIRPORT_STATUS_INFORMATION>' \
    > "$FAA_FILE"

fi


if [ "$WX_OK" -eq 0 ]; then

    echo
    echo "WARNING: Weather data could not be downloaded."

    echo '[]' > "$WX_FILE"

fi


# ============================================================
# GENERATE HTML
# ============================================================

AIRPORT_DATA="$AIRPORTS" \
python3 - "$FAA_FILE" "$WX_FILE" "$OUTPUT_FILE" <<'PYTHON'

import sys
import os
import json
import html
import xml.etree.ElementTree as ET

from datetime import datetime, timezone


faa_file = sys.argv[1]
wx_file = sys.argv[2]
output_file = sys.argv[3]


airport_text = os.environ.get("AIRPORT_DATA", "")

airports = []


for line in airport_text.splitlines():

    line = line.strip()

    if not line:
        continue

    parts = line.split("|", 2)

    if len(parts) == 3:

        airports.append({
            "faa": parts[0],
            "icao": parts[1],
            "name": parts[2]
        })


# ============================================================
# GENERAL HELPERS
# ============================================================

def clean(value):

    if value is None:
        return ""

    return " ".join(str(value).split())


def safe(value):

    return html.escape(str(value))


# ============================================================
# PARSE FAA XML
# ============================================================

faa_status = {}

faa_update = "Unavailable"


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

                        fields.setdefault(
                            tag,
                            value
                        )


            faa_status.setdefault(
                airport,
                []
            ).append({

                "type": delay_name,

                "fields": fields

            })


except Exception:

    pass


# ============================================================
# REMOVE DUPLICATE FAA RECORDS
# ============================================================

for code in list(faa_status.keys()):

    seen = set()

    unique = []


    for event in faa_status[code]:

        key = (

            event["type"],

            tuple(
                sorted(
                    event["fields"].items()
                )
            )

        )


        if key not in seen:

            seen.add(key)

            unique.append(event)


    faa_status[code] = unique


# ============================================================
# PARSE WEATHER JSON
# ============================================================

weather = {}


try:

    with open(
        wx_file,
        "r",
        encoding="utf-8"
    ) as f:

        data = json.load(f)


    if isinstance(data, dict):

        data = data.get(
            "data",
            [data]
        )


    if not isinstance(data, list):

        data = []


    for item in data:

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


except Exception:

    pass


# ============================================================
# WEATHER FUNCTIONS
# ============================================================

def get_value(item, *keys):

    for key in keys:

        if key in item:

            value = item[key]

            if value not in (
                None,
                ""
            ):

                return value

    return None


def flight_category(item):

    value = get_value(
        item,
        "fltCat",
        "flight_category",
        "flightCategory"
    )

    if value:

        return str(value).upper()

    return "N/A"


def visibility(item):

    value = get_value(
        item,
        "visib",
        "visibility"
    )


    if value is None:

        return "N/A"


    try:

        return f"{float(value):g} mi"

    except:

        return str(value)


def wind(item):

    direction = get_value(
        item,
        "wdir",
        "windDir"
    )

    speed = get_value(
        item,
        "wspd",
        "windSpeed"
    )

    gust = get_value(
        item,
        "wgst",
        "windGust"
    )


    if speed is None:

        return "N/A"


    try:

        speed = int(float(speed))

    except:

        pass


    if direction is None:

        direction = "VAR"

    else:

        try:

            direction = \
                f"{int(float(direction)):03d}"

        except:

            direction = str(direction)


    result = f"{direction}/{speed} kt"


    if gust not in (
        None,
        "",
        0,
        "0"
    ):

        try:

            result += \
                f" G{int(float(gust))}"

        except:

            result += \
                f" G{gust}"


    return result


def ceiling(item):

    clouds = item.get(
        "clouds",
        []
    )


    if isinstance(clouds, list):

        ceilings = []


        for cloud in clouds:

            if not isinstance(
                cloud,
                dict
            ):

                continue


            cover = str(
                cloud.get(
                    "cover",
                    ""
                )
            ).upper()


            base = cloud.get(
                "base"
            )


            if (
                cover in (
                    "BKN",
                    "OVC",
                    "VV"
                )
                and base is not None
            ):

                try:

                    ceilings.append(
                        (
                            int(float(base)),
                            cover
                        )
                    )

                except:

                    pass


        if ceilings:

            ceilings.sort()

            altitude, cover = \
                ceilings[0]

            return \
                f"{cover} {altitude:,} ft"


    return "N/A"


def weather_text(item):

    value = get_value(
        item,
        "wxString",
        "wx",
        "weather"
    )


    if not value:

        return "None"


    return str(value)


# ============================================================
# FAA STATUS FUNCTIONS
# ============================================================

def status_label(events):

    if not events:

        return "NORMAL"


    names = [

        event["type"].lower()

        for event in events

    ]


    if any(
        "closure" in x
        for x in names
    ):

        return "CLOSED"


    if any(
        "ground stop" in x
        for x in names
    ):

        return "GROUND STOP"


    if any(
        "ground delay" in x
        for x in names
    ):

        return "GROUND DELAY"


    if any(
        "arrival" in x
        or "departure" in x

        for x in names
    ):

        return "A/D DELAY"


    return "RESTRICTION"


def status_class(status):

    if status == "NORMAL":

        return "normal"


    if status in (
        "CLOSED",
        "GROUND STOP"
    ):

        return "critical"


    return "warning"


def flight_class(cat):

    cat = cat.upper()


    if cat == "VFR":

        return "vfr"


    if cat == "MVFR":

        return "mvfr"


    if cat == "IFR":

        return "ifr"


    if cat == "LIFR":

        return "lifr"


    return "unknown"


def weather_related(events):

    text = ""


    for event in events:

        text += \
            " " + event["type"]


        for value in \
                event["fields"].values():

            text += \
                " " + str(value)


    text = text.lower()


    terms = [

        "weather",
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


    return any(
        term in text
        for term in terms
    )


def event_details(event):

    fields = event["fields"]


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


    parts = []

    used = set()


    for key in preferred:

        if key in fields:

            parts.append(
                f"<b>{safe(key)}:</b> "
                f"{safe(fields[key])}"
            )

            used.add(key)


    for key, value in fields.items():

        if key not in used:

            parts.append(
                f"<b>{safe(key)}:</b> "
                f"{safe(value)}"
            )


    return \
        " &nbsp; | &nbsp; ".join(parts)


# ============================================================
# BUILD AIRPORT DATA
# ============================================================

rows = []

active = []

weather_alerts = []


for airport in airports:

    code = airport["faa"]

    icao = airport["icao"]

    events = faa_status.get(
        code,
        []
    )

    wx = weather.get(
        icao,
        {}
    )


    status = status_label(events)

    category = flight_category(wx)


    if events:

        active.append(
            (
                airport,
                events
            )
        )


    weather_warning = ""


    if weather_related(events):

        weather_warning = """
        <span class="wxflag">
        FAA WEATHER
        </span>
        """


    rows.append(f"""
    <tr
        data-status="{safe(status)}"
        data-category="{safe(category)}"
        data-airport="{safe(code)} {safe(airport['name'])}"
    >

        <td class="code">
            {safe(code)}
        </td>

        <td class="airport">
            {safe(airport['name'])}
        </td>

        <td>

            <span class="status {status_class(status)}">
                {safe(status)}
            </span>

            {weather_warning}

        </td>

        <td>

            <span class="flight {flight_class(category)}">
                {safe(category)}
            </span>

        </td>

        <td>
            {safe(visibility(wx))}
        </td>

        <td>
            {safe(wind(wx))}
        </td>

        <td>
            {safe(ceiling(wx))}
        </td>

        <td>
            {safe(weather_text(wx))}
        </td>

    </tr>
    """)


    # ========================================================
    # DETERMINE SIGNIFICANT WEATHER
    # ========================================================

    bad_weather = False


    if category in (
        "IFR",
        "LIFR"
    ):

        bad_weather = True


    gust = get_value(
        wx,
        "wgst",
        "windGust"
    )


    try:

        if (
            gust is not None
            and float(gust) >= 30
        ):

            bad_weather = True

    except:

        pass


    vis = get_value(
        wx,
        "visib",
        "visibility"
    )


    try:

        if (
            vis is not None
            and float(vis) < 3
        ):

            bad_weather = True

    except:

        pass


    wx_string = \
        weather_text(wx).upper()


    significant_codes = [

        "TS",
        "FZ",
        "SN",
        "FG",
        "SQ",
        "GR",
        "+RA"

    ]


    if any(
        code in wx_string
        for code in significant_codes
    ):

        bad_weather = True


    if bad_weather:

        weather_alerts.append(
            (
                airport,
                wx
            )
        )


# ============================================================
# ACTIVE FAA DELAYS / RESTRICTIONS
# ============================================================

active_html = ""


if not active:

    active_html = """
    <div class="good-message">
        No FAA restrictions are currently reported
        for the monitored airports.
    </div>
    """


else:

    for airport, events in active:

        status = status_label(events)

        event_html = ""


        for event in events:

            details = \
                event_details(event)


            event_html += f"""
            <div class="event">

                <div class="event-title">
                    {safe(event['type'])}
                </div>

                <div class="event-details">
                    {details}
                </div>

            </div>
            """


        active_html += f"""
        <div class="delay-card {status_class(status)}-card">

            <div class="delay-heading">

                <span class="delay-code">
                    {safe(airport['faa'])}
                </span>

                {safe(airport['name'])}

                <span class="status {status_class(status)}">
                    {safe(status)}
                </span>

            </div>

            {event_html}

        </div>
        """


# ============================================================
# SIGNIFICANT WEATHER
# ============================================================

weather_html = ""


if not weather_alerts:

    weather_html = """
    <div class="good-message">
        No major IFR/LIFR or severe weather conditions
        detected at monitored airports.
    </div>
    """


else:

    for airport, wx in weather_alerts:

        category = \
            flight_category(wx)


        weather_html += f"""
        <div class="weather-card">

            <div class="weather-heading">

                <span class="delay-code">
                    {safe(airport['faa'])}
                </span>

                {safe(airport['name'])}

                <span class="flight {flight_class(category)}">
                    {safe(category)}
                </span>

            </div>

            <div class="weather-details">

                <b>Visibility:</b>
                {safe(visibility(wx))}

                &nbsp; | &nbsp;

                <b>Wind:</b>
                {safe(wind(wx))}

                &nbsp; | &nbsp;

                <b>Ceiling:</b>
                {safe(ceiling(wx))}

                &nbsp; | &nbsp;

                <b>Weather:</b>
                {safe(weather_text(wx))}

            </div>

        </div>
        """


# ============================================================
# SUMMARY STATISTICS
# ============================================================

normal_count = 0

delay_count = 0

ground_stop_count = 0

ground_delay_count = 0

closed_count = 0


for airport in airports:

    status = status_label(

        faa_status.get(
            airport["faa"],
            []
        )

    )


    if status == "NORMAL":

        normal_count += 1

    else:

        delay_count += 1


    if status == "GROUND STOP":

        ground_stop_count += 1


    if status == "GROUND DELAY":

        ground_delay_count += 1


    if status == "CLOSED":

        closed_count += 1


# ============================================================
# TIMES
# ============================================================

local_now = datetime.now().astimezone()

utc_now = datetime.now(timezone.utc)


local_time_text = \
    local_now.strftime(
        "%B %d, %Y %I:%M:%S %p %Z"
    )


utc_time_text = \
    utc_now.strftime(
        "%B %d, %Y %H:%M:%S UTC"
    )


# ============================================================
# GENERATE HTML PAGE
# ============================================================

html_page = f"""<!DOCTYPE html>

<html lang="en">

<head>

<meta charset="UTF-8">

<meta
    name="viewport"
    content="width=device-width, initial-scale=1"
>

<title>
U.S. Airport Status Monitor
</title>


<style>

body {{

    margin: 0;

    background:
        #10151c;

    color:
        #e8edf2;

    font-family:
        Arial,
        Helvetica,
        sans-serif;

}}


header {{

    background:
        #18212b;

    border-bottom:
        1px solid #344150;

    padding:
        22px 30px;

}}


h1 {{

    margin:
        0 0 8px 0;

    font-size:
        28px;

}}


.timestamp {{

    color:
        #aab6c2;

    font-size:
        14px;

    line-height:
        1.7;

}}


.time-label {{

    color:
        #e8edf2;

    font-weight:
        bold;

}}


.container {{

    width:
        96%;

    max-width:
        1700px;

    margin:
        20px auto 50px auto;

}}


.summary {{

    display:
        grid;

    grid-template-columns:
        repeat(
            auto-fit,
            minmax(170px, 1fr)
        );

    gap:
        12px;

    margin-bottom:
        24px;

}}


.summary-card {{

    background:
        #18212b;

    border:
        1px solid #344150;

    border-radius:
        8px;

    padding:
        18px;

}}


.summary-number {{

    font-size:
        30px;

    font-weight:
        bold;

}}


.summary-label {{

    color:
        #aab6c2;

    margin-top:
        4px;

}}


.section-title {{

    margin-top:
        30px;

    margin-bottom:
        12px;

    font-size:
        22px;

    border-bottom:
        1px solid #344150;

    padding-bottom:
        8px;

}}


.controls {{

    background:
        #18212b;

    padding:
        14px;

    border-radius:
        8px;

    margin-bottom:
        15px;

    border:
        1px solid #344150;

}}


.controls input {{

    width:
        300px;

    max-width:
        80%;

    padding:
        9px;

    border-radius:
        5px;

    border:
        1px solid #49586a;

    background:
        #0e141b;

    color:
        white;

}}


.controls button {{

    padding:
        9px 14px;

    margin-left:
        5px;

    border:
        none;

    border-radius:
        5px;

    cursor:
        pointer;

    background:
        #344150;

    color:
        white;

}}


.controls button:hover {{

    background:
        #465668;

}}


.table-wrapper {{

    overflow-x:
        auto;

    background:
        #18212b;

    border-radius:
        8px;

    border:
        1px solid #344150;

}}


table {{

    width:
        100%;

    border-collapse:
        collapse;

    min-width:
        1150px;

}}


th {{

    position:
        sticky;

    top:
        0;

    background:
        #222e3a;

    padding:
        11px 8px;

    text-align:
        left;

    border-bottom:
        2px solid #3d4b5b;

}}


td {{

    padding:
        10px 8px;

    border-bottom:
        1px solid #2a3541;

}}


tr:hover {{

    background:
        #222c36;

}}


.code {{

    font-weight:
        bold;

    font-size:
        16px;

}}


.airport {{

    white-space:
        nowrap;

}}


.status {{

    display:
        inline-block;

    padding:
        5px 8px;

    border-radius:
        4px;

    font-weight:
        bold;

    font-size:
        12px;

}}


.normal {{

    background:
        #1c6438;

    color:
        white;

}}


.warning {{

    background:
        #a66a00;

    color:
        white;

}}


.critical {{

    background:
        #a52020;

    color:
        white;

}}


.flight {{

    display:
        inline-block;

    padding:
        4px 7px;

    font-weight:
        bold;

    border-radius:
        4px;

}}


.vfr {{

    background:
        #1d713d;

}}


.mvfr {{

    background:
        #175ea8;

}}


.ifr {{

    background:
        #a62121;

}}


.lifr {{

    background:
        #7d287f;

}}


.unknown {{

    background:
        #505962;

}}


.wxflag {{

    display:
        inline-block;

    margin-left:
        4px;

    background:
        #5f438c;

    color:
        white;

    padding:
        4px 6px;

    border-radius:
        4px;

    font-size:
        10px;

    font-weight:
        bold;

}}


.delay-card,
.weather-card {{

    background:
        #18212b;

    border:
        1px solid #344150;

    border-radius:
        8px;

    margin-bottom:
        10px;

    overflow:
        hidden;

}}


.critical-card {{

    border-left:
        6px solid #b32323;

}}


.warning-card {{

    border-left:
        6px solid #b77900;

}}


.delay-heading,
.weather-heading {{

    padding:
        13px;

    font-size:
        17px;

    background:
        #202b36;

}}


.delay-code {{

    font-size:
        19px;

    font-weight:
        bold;

    margin-right:
        8px;

}}


.event {{

    padding:
        12px 15px;

    border-top:
        1px solid #344150;

}}


.event-title {{

    font-weight:
        bold;

    margin-bottom:
        6px;

    color:
        #f1ba4b;

}}


.event-details {{

    color:
        #cbd4dc;

    line-height:
        1.6;

}}


.weather-details {{

    padding:
        12px 15px;

    line-height:
        1.7;

}}


.good-message {{

    background:
        #173d29;

    border:
        1px solid #23643e;

    padding:
        15px;

    border-radius:
        7px;

}}


.legend {{

    background:
        #18212b;

    border:
        1px solid #344150;

    border-radius:
        8px;

    padding:
        15px;

    line-height:
        2;

    margin-top:
        30px;

}}


.source {{

    color:
        #8593a0;

    font-size:
        12px;

    margin-top:
        25px;

    line-height:
        1.6;

}}


@media (max-width: 700px) {{

    header {{

        padding:
            16px;

    }}


    h1 {{

        font-size:
            21px;

    }}


    .container {{

        width:
            98%;

    }}


    .controls input {{

        width:
            95%;

        max-width:
            95%;

        margin-bottom:
            8px;

    }}


    .controls button {{

        margin:
            3px;

    }}

}}

</style>

</head>


<body>


<header>

<h1>
U.S. Major Airport Status Monitor
</h1>


<div class="timestamp">

<span class="time-label">
Local Time:
</span>

{safe(local_time_text)}

<br>


<span class="time-label">
UTC Time:
</span>

{safe(utc_time_text)}

<br>


<span class="time-label">
FAA Feed Update:
</span>

{safe(faa_update)}

</div>

</header>


<div class="container">


<!-- ===================================================== -->
<!-- SUMMARY -->
<!-- ===================================================== -->

<div class="summary">


<div class="summary-card">

<div class="summary-number">
{len(airports)}
</div>

<div class="summary-label">
Airports monitored
</div>

</div>


<div class="summary-card">

<div class="summary-number">
{normal_count}
</div>

<div class="summary-label">
Normal
</div>

</div>


<div class="summary-card">

<div class="summary-number">
{delay_count}
</div>

<div class="summary-label">
FAA restrictions
</div>

</div>


<div class="summary-card">

<div class="summary-number">
{ground_stop_count}
</div>

<div class="summary-label">
Ground stops
</div>

</div>


<div class="summary-card">

<div class="summary-number">
{ground_delay_count}
</div>

<div class="summary-label">
Ground delay programs
</div>

</div>


<div class="summary-card">

<div class="summary-number">
{closed_count}
</div>

<div class="summary-label">
Airport closures
</div>

</div>


</div>


<!-- ===================================================== -->
<!-- ACTIVE FAA RESTRICTIONS -->
<!-- ===================================================== -->

<h2 class="section-title">
Active FAA Delays and Restrictions
</h2>


{active_html}


<!-- ===================================================== -->
<!-- SIGNIFICANT WEATHER -->
<!-- ===================================================== -->

<h2 class="section-title">
Significant Airport Weather
</h2>


{weather_html}


<!-- ===================================================== -->
<!-- FULL AIRPORT LIST -->
<!-- ===================================================== -->

<h2 class="section-title">
All Monitored Airports
</h2>


<div class="controls">


<input
    type="text"
    id="searchBox"
    placeholder="Search airport or code..."
    onkeyup="filterTable()"
>


<button onclick="showAll()">
All Airports
</button>


<button onclick="showDelays()">
FAA Delays Only
</button>


<button onclick="showIFR()">
IFR / LIFR Only
</button>


</div>


<div class="table-wrapper">


<table id="airportTable">


<thead>


<tr>

<th>Code</th>

<th>Airport</th>

<th>FAA Status</th>

<th>Flight Category</th>

<th>Visibility</th>

<th>Wind</th>

<th>Ceiling</th>

<th>Weather</th>

</tr>


</thead>


<tbody>


{''.join(rows)}


</tbody>


</table>


</div>


<!-- ===================================================== -->
<!-- LEGEND -->
<!-- ===================================================== -->

<div class="legend">


<b>
FAA Status
</b>

<br>


<span class="status normal">
NORMAL
</span>

No FAA delay program reported

<br>


<span class="status warning">
GROUND DELAY
</span>

FAA Ground Delay Program

<br>


<span class="status critical">
GROUND STOP
</span>

FAA Ground Stop

<br>


<span class="status critical">
CLOSED
</span>

Airport closure reported


<br><br>


<b>
Flight Category
</b>

<br>


<span class="flight vfr">
VFR
</span>

Visual Flight Rules

<br>


<span class="flight mvfr">
MVFR
</span>

Marginal Visual Flight Rules

<br>


<span class="flight ifr">
IFR
</span>

Instrument Flight Rules

<br>


<span class="flight lifr">
LIFR
</span>

Low Instrument Flight Rules


</div>


<div class="source">

FAA status information indicates National Airspace System
airport restrictions and delays.

<br>

Weather information is derived from current aviation METAR
observations.

<br>

Individual airline flight delays and cancellations may differ
from FAA airport-wide status.

</div>


</div>


<!-- ===================================================== -->
<!-- JAVASCRIPT -->
<!-- ===================================================== -->

<script>


function filterTable() {{

    const input =
        document.getElementById(
            "searchBox"
        );


    const filter =
        input.value.toUpperCase();


    const rows =
        document.querySelectorAll(
            "#airportTable tbody tr"
        );


    rows.forEach(row => {{

        const text =
            row.innerText.toUpperCase();


        if (
            text.includes(filter)
        ) {{

            row.style.display = "";

        }}

        else {{

            row.style.display =
                "none";

        }}

    }});

}}


function showAll() {{

    document.getElementById(
        "searchBox"
    ).value = "";


    const rows =
        document.querySelectorAll(
            "#airportTable tbody tr"
        );


    rows.forEach(row => {{

        row.style.display = "";

    }});

}}


function showDelays() {{

    document.getElementById(
        "searchBox"
    ).value = "";


    const rows =
        document.querySelectorAll(
            "#airportTable tbody tr"
        );


    rows.forEach(row => {{

        const status =
            row.getAttribute(
                "data-status"
            );


        if (
            status === "NORMAL"
        ) {{

            row.style.display =
                "none";

        }}

        else {{

            row.style.display =
                "";

        }}

    }});

}}


function showIFR() {{

    document.getElementById(
        "searchBox"
    ).value = "";


    const rows =
        document.querySelectorAll(
            "#airportTable tbody tr"
        );


    rows.forEach(row => {{

        const category =
            row.getAttribute(
                "data-category"
            );


        if (
            category === "IFR"
            ||
            category === "LIFR"
        ) {{

            row.style.display =
                "";

        }}

        else {{

            row.style.display =
                "none";

        }}

    }});

}}


</script>


</body>

</html>
"""


# ============================================================
# WRITE HTML FILE
# ============================================================

os.makedirs(
    os.path.dirname(
        output_file
    ),
    exist_ok=True
)


with open(
    output_file,
    "w",
    encoding="utf-8"
) as f:

    f.write(
        html_page
    )


print()

print(
    "HTML airport status page created:"
)

print(
    output_file
)

PYTHON


# ============================================================
# OPEN HTML PAGE
# ============================================================

echo

echo "Airport status page updated:"

echo "$OUTPUT_FILE"

echo


if command -v xdg-open >/dev/null 2>&1; then

    xdg-open \
        "$OUTPUT_FILE" \
        >/dev/null 2>&1 &

fi


echo

read -r -p "Press ENTER to close."