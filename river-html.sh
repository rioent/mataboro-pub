#!/usr/bin/env bash

# Current River Levels and Flow HTML Report
# Delaware River, Mongaup River, Neversink River
# Data source: USGS Water Services Instantaneous Values API

set -o pipefail

REQUIRED_CMDS=("curl" "jq" "date")

for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Missing required command: $cmd"
        echo
        echo "Install requirements with:"
        echo "sudo apt install curl jq"
        echo
        read -n 1 -s -r -p "Press any key to close..."
        echo
        exit 1
    fi
done

API_URL="https://waterservices.usgs.gov/nwis/iv/"
SITES="01434000,01432160,01433005,01433500,01437500"
PARAMS="00060,00065"

OUTPUT_FILE="river_levels.html"

declare -A SITE_NAMES
SITE_NAMES["01434000"]="Delaware River at Port Jervis, NY"
SITE_NAMES["01432160"]="Delaware River at Barryville, NY"
SITE_NAMES["01433005"]="Mongaup River below Swinging Bridge Reservoir, NY"
SITE_NAMES["01433500"]="Mongaup River near Mongaup, NY"
SITE_NAMES["01437500"]="Neversink River at Godeffroy, NY"

SITE_ORDER=("01434000" "01432160" "01433005" "01433500" "01437500")

TMP_JSON="$(mktemp)"
trap 'rm -f "$TMP_JSON"' EXIT

clear
echo "Loading current USGS river data..."
echo

curl -fsS \
    --connect-timeout 15 \
    --max-time 30 \
    "${API_URL}?format=json&sites=${SITES}&parameterCd=${PARAMS}&siteStatus=all" \
    -o "$TMP_JSON"

if [[ $? -ne 0 || ! -s "$TMP_JSON" ]]; then
    echo "ERROR: Could not retrieve data from USGS."
    echo "Check your internet connection and try again."
    echo
    read -n 1 -s -r -p "Press any key to close..."
    echo
    exit 1
fi

get_param() {
    local site="$1"
    local param="$2"

    jq -r \
        --arg site "$site" \
        --arg param "$param" '
        def latest($site; $param):
          [
            .value.timeSeries[]
            | select(.sourceInfo.siteCode[0].value == $site)
            | select(.variable.variableCode[0].value == $param)
            | {
                value: (.values[0].value[-1].value // "Not reported"),
                unit: (.variable.unit.unitCode // ""),
                time: (.values[0].value[-1].dateTime // "No timestamp"),
                qualifiers: ((.values[0].value[-1].qualifiers // []) | join(","))
              }
          ][0] // {
                value: "Not reported",
                unit: "",
                time: "No timestamp",
                qualifiers: ""
              };

        latest($site; $param)
        | [.value, .unit, .time, .qualifiers]
        | @tsv
        ' "$TMP_JSON"
}

html_escape() {
    sed \
        -e 's/&/\&amp;/g' \
        -e 's/</\&lt;/g' \
        -e 's/>/\&gt;/g' \
        -e 's/"/\&quot;/g' \
        -e "s/'/\&#39;/g"
}

make_html_header() {
cat > "$OUTPUT_FILE" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Current River Levels</title>
<meta name="viewport" content="width=device-width, initial-scale=1.0">

<style>
    body {
        font-family: Arial, Helvetica, sans-serif;
        background: #f4f7fa;
        color: #222;
        margin: 0;
        padding: 0;
    }

    header {
        background: #0b3954;
        color: white;
        padding: 24px;
        text-align: center;
    }

    header h1 {
        margin: 0;
        font-size: 32px;
    }

    header p {
        margin: 8px 0 0 0;
        font-size: 15px;
    }

    main {
        max-width: 1100px;
        margin: 24px auto;
        padding: 0 16px;
    }

    .time-box {
        background: white;
        border-left: 6px solid #0b3954;
        padding: 16px;
        margin-bottom: 24px;
        box-shadow: 0 2px 8px rgba(0,0,0,0.08);
    }

    .time-box p {
        margin: 6px 0;
    }

    table {
        width: 100%;
        border-collapse: collapse;
        background: white;
        box-shadow: 0 2px 8px rgba(0,0,0,0.08);
        margin-bottom: 24px;
    }

    th {
        background: #087e8b;
        color: white;
        text-align: left;
        padding: 12px;
    }

    td {
        border-bottom: 1px solid #ddd;
        padding: 12px;
        vertical-align: top;
    }

    tr:nth-child(even) {
        background: #f8fbfc;
    }

    .site-name {
        font-weight: bold;
    }

    .note {
        background: #fff;
        border-left: 6px solid #bfd7ea;
        padding: 16px;
        margin-bottom: 24px;
        box-shadow: 0 2px 8px rgba(0,0,0,0.08);
    }

    footer {
        text-align: center;
        padding: 18px;
        color: #555;
        font-size: 13px;
    }

    @media screen and (max-width: 700px) {
        table, thead, tbody, th, td, tr {
            display: block;
        }

        thead {
            display: none;
        }

        tr {
            margin-bottom: 16px;
            border: 1px solid #ddd;
        }

        td {
            border-bottom: none;
        }

        td::before {
            font-weight: bold;
            display: block;
            margin-bottom: 4px;
            color: #0b3954;
        }

        td:nth-child(1)::before { content: "River / Gauge"; }
        td:nth-child(2)::before { content: "USGS Site"; }
        td:nth-child(3)::before { content: "Flow"; }
        td:nth-child(4)::before { content: "Gage Height"; }
        td:nth-child(5)::before { content: "Last Updated"; }
    }
</style>

</head>
<body>

<header>
    <h1>Current River Levels</h1>
    <p>Delaware River, Mongaup River, and Neversink River</p>
</header>

<main>

<div class="time-box">
    <p><strong>Local time:</strong> $(date '+%Y-%m-%d %I:%M:%S %p %Z')</p>
    <p><strong>24-hour time:</strong> $(date '+%Y-%m-%d %H:%M:%S %Z')</p>
    <p><strong>UTC time:</strong> $(date -u '+%Y-%m-%d %H:%M:%S UTC')</p>
    <p><strong>Source:</strong> USGS Water Services, provisional real-time data</p>
</div>

<table>
    <thead>
        <tr>
            <th>River / Gauge</th>
            <th>USGS Site</th>
            <th>Flow</th>
            <th>Gage Height</th>
            <th>Last Updated</th>
        </tr>
    </thead>
    <tbody>
EOF
}

add_site_row() {
    local site="$1"
    local name="${SITE_NAMES[$site]}"

    local flow_value flow_unit flow_time flow_qual
    local height_value height_unit height_time height_qual

    IFS=$'\t' read -r flow_value flow_unit flow_time flow_qual < <(get_param "$site" "00060")
    IFS=$'\t' read -r height_value height_unit height_time height_qual < <(get_param "$site" "00065")

    local safe_name
    safe_name="$(echo "$name" | html_escape)"

    local flow_display
    local height_display
    local updated_display

    if [[ "$flow_value" == "Not reported" ]]; then
        flow_display="Not reported"
    else
        flow_display="${flow_value} ${flow_unit}"
    fi

    if [[ "$height_value" == "Not reported" ]]; then
        height_display="Not reported"
    else
        height_display="${height_value} ${height_unit}"
    fi

    if [[ "$flow_time" != "No timestamp" ]]; then
        updated_display="$flow_time"
    elif [[ "$height_time" != "No timestamp" ]]; then
        updated_display="$height_time"
    else
        updated_display="No timestamp"
    fi

cat >> "$OUTPUT_FILE" <<EOF
        <tr>
            <td class="site-name">${safe_name}</td>
            <td>${site}</td>
            <td>${flow_display}</td>
            <td>${height_display}</td>
            <td>${updated_display}</td>
        </tr>
EOF
}

make_html_footer() {
cat >> "$OUTPUT_FILE" <<EOF
    </tbody>
</table>

<div class="note">
    <p><strong>Parameter notes:</strong></p>
    <p><strong>00060</strong> = Discharge / streamflow, normally shown in cubic feet per second.</p>
    <p><strong>00065</strong> = Gage height, normally shown in feet.</p>
    <p>USGS real-time water data is provisional and may be revised.</p>
</div>

</main>

<footer>
    Report generated by local Linux script.
</footer>

</body>
</html>
EOF
}

make_html_header

for site in "${SITE_ORDER[@]}"; do
    add_site_row "$site"
done

make_html_footer

echo "HTML file created:"
echo "$(pwd)/$OUTPUT_FILE"
echo

if command -v xdg-open >/dev/null 2>&1; then
    echo "Opening $OUTPUT_FILE in your browser..."
    xdg-open "$OUTPUT_FILE" >/dev/null 2>&1 &
else
    echo "To open the file manually:"
    echo "file://$(pwd)/$OUTPUT_FILE"
fi

echo
read -n 1 -s -r -p "Press any key to close..."
echo
