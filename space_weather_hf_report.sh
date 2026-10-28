#!/usr/bin/env bash
#
# Space Weather and HF Propagation Report
# Location: 25 Whitehead Road, Sparrow Bush, NY 12780
#
# Uses free NOAA Space Weather Prediction Center data.
# Requires: bash, Python 3, and an Internet connection.
# ~$ sudo apt install python3
#
# Run interactively:
#   ./space_weather_hf_report.sh
#
# Run once without waiting for a key:
#   ./space_weather_hf_report.sh --once
#
# Force plain text without ANSI colors:
#   NO_COLOR=1 ./space_weather_hf_report.sh
#

set -u

if ! command -v python3 >/dev/null 2>&1; then
    echo "Python 3 is required."
    echo "Install it with: sudo apt install python3"
    exit 1
fi

ONCE=0
if [[ "${1:-}" == "--once" ]]; then
    ONCE=1
fi

while true; do
    clear 2>/dev/null || true

    python3 - <<'PYTHON'
from __future__ import annotations

import concurrent.futures
import datetime as dt
import json
import math
import os
import re
import shutil
import sys
import textwrap
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo


# ---------------------------------------------------------------------------
# LOCATION
# ---------------------------------------------------------------------------

LOCATION_NAME = "25 Whitehead Road, Sparrow Bush, NY 12780"
# Approximate coordinates for the Whitehead Road / ZIP 12780 area.
# A few miles of coordinate difference has no practical effect on HF forecasts.
LATITUDE = 41.44
LONGITUDE = -74.72
TIME_ZONE = ZoneInfo("America/New_York")

# NOAA SWPC data sources
URLS = {
    "scales": "https://services.swpc.noaa.gov/products/noaa-scales.json",
    "kp": "https://services.swpc.noaa.gov/products/noaa-planetary-k-index.json",
    "f107_observed": "https://services.swpc.noaa.gov/products/10cm-flux-30-day.json",
    "forecast45": "https://services.swpc.noaa.gov/json/45-day-forecast.json",
    "forecast_text": "https://services.swpc.noaa.gov/text/3-day-forecast.txt",
    "xray": "https://services.swpc.noaa.gov/json/goes/primary/xrays-6-hour.json",
    "protons": "https://services.swpc.noaa.gov/json/goes/primary/integral-protons-plot-6-hour.json",
    "solar_wind_plasma": "https://services.swpc.noaa.gov/products/solar-wind/plasma-1-day.json",
    "solar_wind_mag": "https://services.swpc.noaa.gov/products/solar-wind/mag-1-day.json",
}

CACHE_DIR = Path.home() / ".cache" / "space_weather_hf_report"
CACHE_DIR.mkdir(parents=True, exist_ok=True)

USER_AGENT = (
    "Mozilla/5.0 (X11; Linux x86_64) "
    "SpaceWeatherHFReport/1.0 contact=local-terminal-script"
)

TERM_WIDTH = max(92, min(shutil.get_terminal_size((120, 30)).columns, 150))
USE_COLOR = sys.stdout.isatty() and "NO_COLOR" not in os.environ


# ---------------------------------------------------------------------------
# TERMINAL FORMATTING
# ---------------------------------------------------------------------------

class C:
    RESET = "\033[0m" if USE_COLOR else ""
    BOLD = "\033[1m" if USE_COLOR else ""
    DIM = "\033[2m" if USE_COLOR else ""
    RED = "\033[31m" if USE_COLOR else ""
    GREEN = "\033[32m" if USE_COLOR else ""
    YELLOW = "\033[33m" if USE_COLOR else ""
    BLUE = "\033[34m" if USE_COLOR else ""
    MAGENTA = "\033[35m" if USE_COLOR else ""
    CYAN = "\033[36m" if USE_COLOR else ""
    WHITE = "\033[37m" if USE_COLOR else ""


def hr(char: str = "─") -> str:
    return char * TERM_WIDTH


def center(text: str) -> str:
    return text.center(TERM_WIDTH)


def heading(text: str) -> None:
    print()
    print(C.BOLD + C.CYAN + text + C.RESET)
    print(C.CYAN + hr("─") + C.RESET)


def safe_float(value: Any) -> float | None:
    try:
        number = float(value)
        return number if math.isfinite(number) else None
    except (TypeError, ValueError):
        return None


def fmt(value: Any, digits: int = 1, missing: str = "Unavailable") -> str:
    number = safe_float(value)
    return missing if number is None else f"{number:.{digits}f}"


def fmt_sci(value: Any, digits: int = 2, missing: str = "Unavailable") -> str:
    number = safe_float(value)
    return missing if number is None else f"{number:.{digits}e}"


def color_rating(rating: str) -> str:
    palette = {
        "Excellent": C.GREEN + C.BOLD,
        "Very Good": C.GREEN,
        "Good": C.CYAN,
        "Fair": C.YELLOW,
        "Poor": C.RED,
        "Very Poor": C.RED + C.BOLD,
    }
    return palette.get(rating, "") + rating + C.RESET


def scale_color(letter: str, value: int | None) -> str:
    if value is None:
        return C.DIM
    if value <= 0:
        return C.GREEN
    if value == 1:
        return C.YELLOW
    if value == 2:
        return C.YELLOW + C.BOLD
    return C.RED + C.BOLD


def wrap_print(label: str, text: str, indent: int = 2) -> None:
    if not text:
        return
    prefix = " " * indent + label
    subsequent = " " * len(prefix)
    print(textwrap.fill(
        text,
        width=TERM_WIDTH,
        initial_indent=prefix,
        subsequent_indent=subsequent,
    ))


# ---------------------------------------------------------------------------
# DOWNLOAD AND CACHE
# ---------------------------------------------------------------------------

def cache_path(key: str) -> Path:
    return CACHE_DIR / f"{key}.cache.json"


def save_cache(key: str, payload: Any, data_type: str) -> None:
    wrapper = {
        "saved_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "data_type": data_type,
        "payload": payload,
    }
    cache_path(key).write_text(json.dumps(wrapper), encoding="utf-8")


def load_cache(key: str) -> tuple[Any, dt.datetime | None] | tuple[None, None]:
    path = cache_path(key)
    if not path.exists():
        return None, None
    try:
        wrapper = json.loads(path.read_text(encoding="utf-8"))
        saved = dt.datetime.fromisoformat(wrapper["saved_utc"])
        return wrapper["payload"], saved
    except Exception:
        return None, None


def download(key: str, url: str, data_type: str = "json") -> dict[str, Any]:
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": USER_AGENT,
            "Accept": "application/json,text/plain,*/*",
            "Cache-Control": "no-cache",
        },
    )

    try:
        with urllib.request.urlopen(request, timeout=14) as response:
            raw = response.read().decode("utf-8", errors="replace")
        payload = json.loads(raw) if data_type == "json" else raw
        save_cache(key, payload, data_type)
        return {
            "payload": payload,
            "live": True,
            "cached_at": None,
            "error": None,
        }
    except Exception as exc:
        payload, saved = load_cache(key)
        return {
            "payload": payload,
            "live": False,
            "cached_at": saved,
            "error": str(exc),
        }


def fetch_all() -> dict[str, dict[str, Any]]:
    tasks = {
        key: (url, "text" if key == "forecast_text" else "json")
        for key, url in URLS.items()
    }

    results: dict[str, dict[str, Any]] = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=9) as pool:
        future_map = {
            pool.submit(download, key, url, kind): key
            for key, (url, kind) in tasks.items()
        }
        for future in concurrent.futures.as_completed(future_map):
            key = future_map[future]
            try:
                results[key] = future.result()
            except Exception as exc:
                results[key] = {
                    "payload": None,
                    "live": False,
                    "cached_at": None,
                    "error": str(exc),
                }
    return results


# ---------------------------------------------------------------------------
# DATE, TIME, SUNRISE, AND SUNSET
# ---------------------------------------------------------------------------

def normalize_degrees(value: float) -> float:
    return value % 360.0


def solar_event_utc(
    date_value: dt.date,
    latitude: float,
    longitude: float,
    sunrise: bool,
) -> dt.datetime | None:
    """NOAA-style sunrise/sunset approximation using 90.833° zenith."""
    day_number = date_value.timetuple().tm_yday
    longitude_hour = longitude / 15.0
    approximate_time = day_number + (
        (6.0 - longitude_hour) / 24.0
        if sunrise
        else (18.0 - longitude_hour) / 24.0
    )

    mean_anomaly = (0.9856 * approximate_time) - 3.289
    true_longitude = (
        mean_anomaly
        + 1.916 * math.sin(math.radians(mean_anomaly))
        + 0.020 * math.sin(math.radians(2 * mean_anomaly))
        + 282.634
    )
    true_longitude = normalize_degrees(true_longitude)

    right_ascension = math.degrees(
        math.atan(0.91764 * math.tan(math.radians(true_longitude)))
    )
    right_ascension = normalize_degrees(right_ascension)

    longitude_quadrant = math.floor(true_longitude / 90.0) * 90.0
    ra_quadrant = math.floor(right_ascension / 90.0) * 90.0
    right_ascension += longitude_quadrant - ra_quadrant
    right_ascension /= 15.0

    sin_declination = 0.39782 * math.sin(math.radians(true_longitude))
    cos_declination = math.cos(math.asin(sin_declination))

    zenith = 90.833
    cos_hour_angle = (
        math.cos(math.radians(zenith))
        - sin_declination * math.sin(math.radians(latitude))
    ) / (cos_declination * math.cos(math.radians(latitude)))

    if cos_hour_angle < -1.0 or cos_hour_angle > 1.0:
        return None

    if sunrise:
        local_hour_angle = 360.0 - math.degrees(math.acos(cos_hour_angle))
    else:
        local_hour_angle = math.degrees(math.acos(cos_hour_angle))
    local_hour_angle /= 15.0

    local_mean_time = (
        local_hour_angle
        + right_ascension
        - 0.06571 * approximate_time
        - 6.622
    )
    utc_hour = (local_mean_time - longitude_hour) % 24.0

    midnight = dt.datetime.combine(
        date_value,
        dt.time(0, 0),
        tzinfo=dt.timezone.utc,
    )
    base_event = midnight + dt.timedelta(hours=utc_hour)

    # Sunset in the eastern United States often occurs shortly after 00:00 UTC
    # on the following UTC date. Pick the UTC candidate that converts back to
    # the requested local calendar date.
    candidates = [
        base_event - dt.timedelta(days=1),
        base_event,
        base_event + dt.timedelta(days=1),
    ]
    for candidate in candidates:
        if candidate.astimezone(TIME_ZONE).date() == date_value:
            return candidate
    return base_event


def sun_times(date_value: dt.date) -> tuple[dt.datetime | None, dt.datetime | None]:
    sunrise_utc = solar_event_utc(date_value, LATITUDE, LONGITUDE, True)
    sunset_utc = solar_event_utc(date_value, LATITUDE, LONGITUDE, False)
    sunrise_local = sunrise_utc.astimezone(TIME_ZONE) if sunrise_utc else None
    sunset_local = sunset_utc.astimezone(TIME_ZONE) if sunset_utc else None
    return sunrise_local, sunset_local


def clock(value: dt.datetime | None) -> str:
    if value is None:
        return "N/A"
    return value.strftime("%-I:%M %p")


def add_hours(value: dt.datetime | None, hours: float) -> dt.datetime | None:
    return value + dt.timedelta(hours=hours) if value else None


# ---------------------------------------------------------------------------
# NOAA DATA PARSING
# ---------------------------------------------------------------------------

def latest_dict_row(payload: Any, time_field: str = "time_tag") -> dict[str, Any] | None:
    if not isinstance(payload, list):
        return None
    rows = [row for row in payload if isinstance(row, dict)]
    if not rows:
        return None
    rows.sort(key=lambda row: str(row.get(time_field, "")))
    return rows[-1]


def parse_table_array(payload: Any) -> dict[str, Any] | None:
    """Parse NOAA array data where the first row contains column names."""
    if not isinstance(payload, list) or len(payload) < 2:
        return None
    header = payload[0]
    if not isinstance(header, list):
        return None

    for row in reversed(payload[1:]):
        if not isinstance(row, list) or len(row) != len(header):
            continue
        record = dict(zip(header, row))
        numeric_count = sum(
            safe_float(value) is not None
            for key, value in record.items()
            if key != "time_tag"
        )
        if numeric_count:
            return record
    return None


def latest_xray(payload: Any) -> dict[str, Any] | None:
    if not isinstance(payload, list):
        return None

    candidates = []
    for row in payload:
        if not isinstance(row, dict):
            continue
        energy = str(row.get("energy", "")).lower().replace(" ", "")
        if "0.1-0.8" in energy or "0.1—0.8" in energy:
            candidates.append(row)

    if not candidates:
        candidates = [row for row in payload if isinstance(row, dict)]

    if not candidates:
        return None

    candidates.sort(key=lambda row: str(row.get("time_tag", "")))
    return candidates[-1]


def xray_flux_from_row(row: dict[str, Any] | None) -> float | None:
    if not row:
        return None
    for key in ("observed_flux", "flux", "value"):
        value = safe_float(row.get(key))
        if value is not None and value >= 0:
            return value
    return None


def xray_class(flux: float | None) -> str:
    if flux is None or flux <= 0:
        return "Unavailable"
    classes = [
        ("X", 1e-4),
        ("M", 1e-5),
        ("C", 1e-6),
        ("B", 1e-7),
        ("A", 1e-8),
    ]
    for letter, base in classes:
        if flux >= base:
            return f"{letter}{flux / base:.1f}"
    return f"A{flux / 1e-8:.1f}"


def latest_proton_flux(payload: Any) -> float | None:
    if not isinstance(payload, list):
        return None

    candidates = []
    for row in payload:
        if not isinstance(row, dict):
            continue
        energy = str(row.get("energy", "")).lower().replace(" ", "")
        if "10" in energy and ("mev" in energy or ">=" in energy or ">" in energy):
            candidates.append(row)

    if not candidates:
        return None

    candidates.sort(key=lambda row: str(row.get("time_tag", "")))
    latest = candidates[-1]
    for key in ("flux", "observed_flux", "value"):
        value = safe_float(latest.get(key))
        if value is not None and value >= 0:
            return value
    return None


def parse_45_day(payload: Any) -> dict[dt.date, dict[str, float]]:
    result: dict[dt.date, dict[str, float]] = {}
    if not isinstance(payload, dict):
        return result

    for row in payload.get("data", []):
        if not isinstance(row, dict):
            continue
        try:
            date_value = dt.datetime.fromisoformat(
                str(row.get("time", "")).replace("Z", "+00:00")
            ).date()
        except ValueError:
            continue

        metric = str(row.get("metric", "")).lower()
        value = safe_float(row.get("value"))
        if metric in {"ap", "f107"} and value is not None:
            result.setdefault(date_value, {})[metric] = value

    return result


def parse_scales(payload: Any) -> tuple[dict[str, Any], dict[dt.date, dict[str, Any]]]:
    current: dict[str, Any] = {}
    by_date: dict[dt.date, dict[str, Any]] = {}

    if not isinstance(payload, dict):
        return current, by_date

    if isinstance(payload.get("0"), dict):
        current = payload["0"]

    for value in payload.values():
        if not isinstance(value, dict):
            continue
        date_text = value.get("DateStamp")
        try:
            date_value = dt.date.fromisoformat(str(date_text))
        except ValueError:
            continue

        # Forecast objects include probabilities. Observed objects usually do not.
        r_data = value.get("R") if isinstance(value.get("R"), dict) else {}
        s_data = value.get("S") if isinstance(value.get("S"), dict) else {}
        g_data = value.get("G") if isinstance(value.get("G"), dict) else {}

        record = {
            "r_minor": safe_float(r_data.get("MinorProb")),
            "r_major": safe_float(r_data.get("MajorProb")),
            "s_prob": safe_float(s_data.get("Prob")),
            "g_scale": safe_float(g_data.get("Scale")),
        }

        if any(item is not None for item in record.values()):
            existing = by_date.get(date_value, {})
            existing.update({
                key: value2
                for key, value2 in record.items()
                if value2 is not None
            })
            by_date[date_value] = existing

    return current, by_date


def parse_forecast_rationales(text: Any) -> list[str]:
    if not isinstance(text, str):
        return []

    normalized = re.sub(r"\s+", " ", text).strip()
    rationales = re.findall(
        r"Rationale:\s*(.*?)(?=\s+[ABC]\.\s+NOAA|\s*$)",
        normalized,
        flags=re.IGNORECASE,
    )

    cleaned = []
    for item in rationales:
        item = re.sub(r"\s+", " ", item).strip()
        if len(item) > 30:
            cleaned.append(item)
    return cleaned[:3]


def scale_number(current: dict[str, Any], letter: str) -> int | None:
    value = current.get(letter, {}) if isinstance(current, dict) else {}
    if not isinstance(value, dict):
        return None
    number = safe_float(value.get("Scale"))
    return int(number) if number is not None else None


def ap_to_kp(ap: float | None) -> float | None:
    if ap is None:
        return None
    thresholds = [
        (2, 1.0),
        (4, 2.0),
        (7, 3.0),
        (15, 4.0),
        (27, 5.0),
        (48, 6.0),
        (80, 7.0),
        (132, 8.0),
        (10_000, 9.0),
    ]
    for limit, kp_value in thresholds:
        if ap <= limit:
            return kp_value
    return 9.0


# ---------------------------------------------------------------------------
# PROPAGATION MODEL
# ---------------------------------------------------------------------------

BANDS = [
    {"band": "160 m", "mhz": 1.8,  "type": "low",  "service": "Local/regional at night"},
    {"band": "80 m",  "mhz": 3.5,  "type": "low",  "service": "Regional/nighttime DX"},
    {"band": "60 m",  "mhz": 5.3,  "type": "low",  "service": "Regional/NVIS and night DX"},
    {"band": "40 m",  "mhz": 7.1,  "type": "mid",  "service": "Regional by day, DX at night"},
    {"band": "30 m",  "mhz": 10.1, "type": "mid",  "service": "Reliable CW/digital DX"},
    {"band": "20 m",  "mhz": 14.2, "type": "high", "service": "Primary daytime DX"},
    {"band": "17 m",  "mhz": 18.1, "type": "high", "service": "Daytime and evening DX"},
    {"band": "15 m",  "mhz": 21.3, "type": "high", "service": "Daytime DX"},
    {"band": "12 m",  "mhz": 24.9, "type": "high", "service": "High-MUF daytime DX"},
    {"band": "10 m",  "mhz": 28.4, "type": "high", "service": "High-MUF DX and sporadic-E"},
]


def season_name(date_value: dt.date) -> str:
    month = date_value.month
    if month in (12, 1, 2):
        return "winter"
    if month in (3, 4, 5):
        return "spring"
    if month in (6, 7, 8):
        return "summer"
    return "autumn"


def band_window(
    band: str,
    sunrise: dt.datetime | None,
    sunset: dt.datetime | None,
) -> str:
    if not sunrise or not sunset:
        return "See local day/night cycle"

    windows = {
        "160 m": (add_hours(sunset, 1.0), add_hours(sunrise, -0.5)),
        "80 m":  (add_hours(sunset, 0.5), sunrise),
        "60 m":  (sunset, add_hours(sunrise, 1.0)),
        "40 m":  (add_hours(sunset, -1.0), add_hours(sunrise, 2.0)),
        "30 m":  (add_hours(sunrise, 0.5), add_hours(sunset, 2.0)),
        "20 m":  (add_hours(sunrise, 1.0), add_hours(sunset, 2.0)),
        "17 m":  (add_hours(sunrise, 2.0), add_hours(sunset, 1.0)),
        "15 m":  (add_hours(sunrise, 3.0), add_hours(sunset, 0.5)),
        "12 m":  (add_hours(sunrise, 4.0), sunset),
        "10 m":  (add_hours(sunrise, 4.0), sunset),
    }

    start, end = windows[band]
    return f"{clock(start)} to {clock(end)}"


def rating_from_score(score: float) -> str:
    if score >= 80:
        return "Excellent"
    if score >= 68:
        return "Very Good"
    if score >= 55:
        return "Good"
    if score >= 42:
        return "Fair"
    if score >= 25:
        return "Poor"
    return "Very Poor"


def propagation_score(
    band: str,
    f107: float,
    ap: float,
    r_minor_probability: float,
    date_value: dt.date,
) -> float:
    ionization = max(0.0, min(1.0, (f107 - 70.0) / 130.0))

    base = {
        "160 m": 66.0 - 5.0 * ionization,
        "80 m":  70.0 - 2.0 * ionization,
        "60 m":  74.0,
        "40 m":  76.0 + 4.0 * ionization,
        "30 m":  56.0 + 29.0 * ionization,
        "20 m":  43.0 + 45.0 * ionization,
        "17 m":  34.0 + 54.0 * ionization,
        "15 m":  24.0 + 64.0 * ionization,
        "12 m":  14.0 + 70.0 * ionization,
        "10 m":   7.0 + 78.0 * ionization,
    }[band]

    geomagnetic_factor = {
        "160 m": 0.55,
        "80 m":  0.55,
        "60 m":  0.60,
        "40 m":  0.68,
        "30 m":  0.78,
        "20 m":  0.90,
        "17 m":  1.00,
        "15 m":  1.05,
        "12 m":  1.10,
        "10 m":  1.10,
    }[band]
    geomagnetic_penalty = max(0.0, ap - 4.0) * geomagnetic_factor

    # A flare-driven radio blackout affects sunlit paths. The practical daily
    # penalty is weighted more heavily on normal daytime bands.
    blackout_factor = {
        "160 m": 0.06,
        "80 m":  0.08,
        "60 m":  0.12,
        "40 m":  0.18,
        "30 m":  0.24,
        "20 m":  0.28,
        "17 m":  0.30,
        "15 m":  0.31,
        "12 m":  0.32,
        "10 m":  0.32,
    }[band]
    blackout_penalty = r_minor_probability * blackout_factor

    noise_penalty = 0.0
    if season_name(date_value) == "summer":
        noise_penalty = {
            "160 m": 18.0,
            "80 m":  11.0,
            "60 m":   5.0,
        }.get(band, 0.0)

    score = base - geomagnetic_penalty - blackout_penalty - noise_penalty

    # Sporadic-E is common enough in late spring and summer to keep 10/12 m
    # from being rated solely by F-region solar flux.
    if date_value.month in (5, 6, 7, 8) and band in ("10 m", "12 m"):
        score += 8.0

    return max(0.0, min(100.0, score))


def band_note(
    band: str,
    score: float,
    f107: float,
    ap: float,
    r_probability: float,
    date_value: dt.date,
) -> str:
    notes = []

    if ap >= 30:
        notes.append("severely storm-disturbed")
    elif ap >= 20:
        notes.append("storm-disturbed")
    elif ap >= 12:
        notes.append("unsettled")
    elif ap <= 7:
        notes.append("geomagnetically quiet")

    if band in ("10 m", "12 m", "15 m", "17 m", "20 m"):
        if f107 >= 170:
            notes.append("strong ionization")
        elif f107 >= 130:
            notes.append("useful ionization")
        else:
            notes.append("limited high-band support")

    if r_probability >= 50 and band in (
        "40 m", "30 m", "20 m", "17 m", "15 m", "12 m", "10 m"
    ):
        notes.append("daylight flare fadeouts possible")

    if season_name(date_value) == "summer" and band in ("160 m", "80 m", "60 m"):
        notes.append("summer static/QRN likely")

    if date_value.month in (5, 6, 7, 8) and band in ("10 m", "12 m"):
        notes.append("sporadic-E may outperform forecast")

    if not notes:
        notes.append("normal day/night behavior expected")

    return "; ".join(notes[:3])


def current_open_factor(
    band: str,
    local_now: dt.datetime,
    sunrise: dt.datetime | None,
    sunset: dt.datetime | None,
) -> float:
    if not sunrise or not sunset:
        return 1.0

    hour = local_now.hour + local_now.minute / 60.0
    sr = sunrise.hour + sunrise.minute / 60.0
    ss = sunset.hour + sunset.minute / 60.0
    is_day = sr <= hour <= ss

    if band in ("160 m", "80 m"):
        return 0.35 if is_day else 1.0
    if band == "60 m":
        return 0.70 if is_day else 1.0
    if band == "40 m":
        return 0.85 if is_day else 1.0
    if band == "30 m":
        return 1.0
    if band == "20 m":
        return 1.0 if is_day else 0.75
    if band in ("17 m", "15 m"):
        return 1.0 if is_day else 0.55
    if band in ("12 m", "10 m"):
        return 1.0 if is_day else 0.30
    return 1.0


# ---------------------------------------------------------------------------
# BUILD REPORT
# ---------------------------------------------------------------------------

results = fetch_all()
now_utc = dt.datetime.now(dt.timezone.utc)
now_local = now_utc.astimezone(TIME_ZONE)
today = now_local.date()
sunrise_today, sunset_today = sun_times(today)

payload = lambda key: results.get(key, {}).get("payload")

# Current observed values
kp_row = latest_dict_row(payload("kp"))
current_kp = safe_float(kp_row.get("Kp")) if kp_row else None
current_ap_running = safe_float(kp_row.get("a_running")) if kp_row else None
kp_time = kp_row.get("time_tag") if kp_row else None

f107_row = latest_dict_row(payload("f107_observed"))
observed_f107 = safe_float(f107_row.get("flux")) if f107_row else None
f107_time = f107_row.get("time_tag") if f107_row else None

plasma_row = parse_table_array(payload("solar_wind_plasma"))
mag_row = parse_table_array(payload("solar_wind_mag"))

solar_wind_speed = safe_float(plasma_row.get("speed")) if plasma_row else None
solar_wind_density = safe_float(plasma_row.get("density")) if plasma_row else None
solar_wind_temp = safe_float(plasma_row.get("temperature")) if plasma_row else None
imf_bz = safe_float(mag_row.get("bz_gsm")) if mag_row else None
imf_bt = safe_float(mag_row.get("bt")) if mag_row else None

xray_row = latest_xray(payload("xray"))
xray_flux = xray_flux_from_row(xray_row)
xray_level = xray_class(xray_flux)
proton_flux = latest_proton_flux(payload("protons"))

current_scales, scale_forecasts = parse_scales(payload("scales"))
r_scale = scale_number(current_scales, "R")
s_scale = scale_number(current_scales, "S")
g_scale = scale_number(current_scales, "G")

forecast_data = parse_45_day(payload("forecast45"))
rationales = parse_forecast_rationales(payload("forecast_text"))

# Determine whether the site is in daylight
daylight_now = False
if sunrise_today and sunset_today:
    daylight_now = sunrise_today <= now_local <= sunset_today

# Data status
live_count = sum(1 for item in results.values() if item.get("live"))
cache_count = sum(
    1
    for item in results.values()
    if not item.get("live") and item.get("payload") is not None
)
missing_count = len(results) - live_count - cache_count

# Header
print(C.BOLD + C.BLUE + hr("═") + C.RESET)
print(C.BOLD + C.WHITE + center("SPACE WEATHER AND HF PROPAGATION REPORT") + C.RESET)
print(C.BOLD + C.WHITE + center("160 THROUGH 10 METERS") + C.RESET)
print(C.BLUE + hr("═") + C.RESET)
print(f"{C.BOLD}Location:{C.RESET} {LOCATION_NAME}")
print(
    f"{C.BOLD}Coordinates used:{C.RESET} "
    f"{LATITUDE:.2f}° N, {abs(LONGITUDE):.2f}° W  "
    f"{C.DIM}(approximate local coordinates){C.RESET}"
)
print(
    f"{C.BOLD}Updated:{C.RESET} "
    f"{now_local.strftime('%A, %B %-d, %Y  %-I:%M:%S %p %Z')}  |  "
    f"{now_utc.strftime('%H:%M:%S UTC')}"
)
status_text = (
    f"{C.GREEN}{live_count} live NOAA feeds{C.RESET}, "
    f"{C.YELLOW}{cache_count} cached feeds{C.RESET}, "
    f"{C.RED}{missing_count} unavailable feeds{C.RESET}"
)
print(f"{C.BOLD}Data status:{C.RESET} {status_text}")

# Detailed current conditions
heading("DETAILED CURRENT SPACE WEATHER CONDITIONS")

day_night = "DAYLIGHT" if daylight_now else "NIGHT"
day_night_color = C.YELLOW if daylight_now else C.BLUE
print(
    f"  Local solar period : {day_night_color}{C.BOLD}{day_night}{C.RESET}  |  "
    f"Sunrise {clock(sunrise_today)}  |  Sunset {clock(sunset_today)}"
)

scale_parts = []
for letter, number, meaning in (
    ("R", r_scale, "radio blackout"),
    ("S", s_scale, "solar radiation"),
    ("G", g_scale, "geomagnetic"),
):
    scale_label = f"{letter}{number}" if number is not None else f"{letter} unavailable"
    scale_parts.append(
        f"{scale_color(letter, number)}{scale_label}{C.RESET} {meaning}"
    )
print(f"  NOAA scales        : {'  |  '.join(scale_parts)}")

kp_description = "Unavailable"
if current_kp is not None:
    if current_kp < 2:
        kp_description = "very quiet"
    elif current_kp < 4:
        kp_description = "quiet to unsettled"
    elif current_kp < 5:
        kp_description = "active"
    elif current_kp < 6:
        kp_description = "minor storm"
    elif current_kp < 7:
        kp_description = "moderate storm"
    elif current_kp < 8:
        kp_description = "strong storm"
    else:
        kp_description = "severe/extreme storm"

print(
    f"  Planetary Kp       : {fmt(current_kp, 2)}  "
    f"({kp_description})  |  3-hour a-index equivalent {fmt(current_ap_running, 0)}"
)
print(
    f"  Solar flux F10.7   : {fmt(observed_f107, 0)} sfu  "
    f"(higher values generally support higher HF bands)"
)
print(
    f"  GOES X-ray level   : {xray_level}  |  "
    f"Long-channel flux {fmt_sci(xray_flux, 2, 'Unavailable')} W/m²"
)
print(
    f"  >10 MeV protons    : {fmt(proton_flux, 3)} pfu  |  "
    f"S1 threshold is 10 pfu"
)
print(
    f"  Solar wind         : {fmt(solar_wind_speed, 0)} km/s  |  "
    f"Density {fmt(solar_wind_density, 1)} p/cm³  |  "
    f"Temperature {fmt(solar_wind_temp, 0)} K"
)
bz_text = fmt(imf_bz, 1)
if imf_bz is not None:
    if imf_bz <= -10:
        bz_text += " nT, strongly southward"
    elif imf_bz <= -5:
        bz_text += " nT, southward"
    elif imf_bz < 0:
        bz_text += " nT, slightly southward"
    else:
        bz_text += " nT, northward/non-negative"
print(
    f"  Interplanetary Bz  : {bz_text}  |  "
    f"Total field Bt {fmt(imf_bt, 1)} nT"
)

if kp_time or f107_time:
    print(
        f"  Observation times  : "
        f"Kp {kp_time or 'Unavailable'}  |  "
        f"F10.7 {f107_time or 'Unavailable'}"
    )

# Current overall assessment
if current_kp is None and observed_f107 is None:
    assessment = (
        "Current NOAA observations could not be downloaded and no cached data "
        "was available. Check the Internet connection and run the report again."
    )
else:
    messages = []
    if current_kp is not None:
        if current_kp >= 7:
            messages.append(
                "Strong geomagnetic storming is likely to suppress or destabilize "
                "F-region DX, especially on north-south and polar paths."
            )
        elif current_kp >= 5:
            messages.append(
                "Geomagnetic storming may reduce MUF, increase fading, and disturb "
                "long-distance paths."
            )
        elif current_kp >= 4:
            messages.append(
                "Active geomagnetic conditions may produce uneven DX and rapid fading."
            )
        else:
            messages.append(
                "Geomagnetic conditions are reasonably supportive of normal HF paths."
            )

    if r_scale is not None and r_scale >= 2:
        messages.append(
            "A current radio blackout is degrading the sunlit side of Earth, with "
            "the lower HF frequencies generally affected first and most strongly."
        )
    elif r_scale == 1:
        messages.append(
            "Minor sunlit-side HF degradation is possible from elevated X-ray flux."
        )

    if observed_f107 is not None:
        if observed_f107 >= 170:
            messages.append(
                "Solar ionization is strong enough to support 20 through 10 meters "
                "when geomagnetic conditions and the local day/night path cooperate."
            )
        elif observed_f107 >= 130:
            messages.append(
                "Solar ionization should support 20 and 17 meters, with possible "
                "openings on 15 through 10 meters."
            )
        else:
            messages.append(
                "Solar ionization favors the lower and middle HF bands; upper-band "
                "openings may be shorter or path-specific."
            )

    assessment = " ".join(messages)

wrap_print("Assessment: ", assessment)

# Forecast inputs for today plus three days
heading("DAILY SPACE WEATHER FORECAST: TODAY PLUS THE NEXT THREE DAYS")

print(
    f"  {'Date':<16} {'F10.7':>7} {'Ap':>6} {'Est Kp':>8} "
    f"{'G':>4} {'R1-R2':>8} {'R3+':>7} {'S1+':>7}  Daily HF environment"
)
print("  " + "─" * min(TERM_WIDTH - 2, 116))

daily_records = []

for offset in range(4):
    date_value = today + dt.timedelta(days=offset)
    day_data = forecast_data.get(date_value, {})

    f107 = safe_float(day_data.get("f107"))
    ap = safe_float(day_data.get("ap"))

    # Sensible fallbacks when one NOAA product is temporarily unavailable.
    if f107 is None:
        f107 = observed_f107
    if ap is None:
        ap = current_ap_running if offset == 0 else None

    scale_data = scale_forecasts.get(date_value, {})
    r_minor = safe_float(scale_data.get("r_minor"))
    r_major = safe_float(scale_data.get("r_major"))
    s_prob = safe_float(scale_data.get("s_prob"))
    forecast_g = safe_float(scale_data.get("g_scale"))

    # Day four normally exceeds the 3-day probability product.
    # Use a conservative neutral estimate and label it as model-derived below.
    probability_estimated = False
    if r_minor is None and f107 is not None:
        probability_estimated = True
        if f107 >= 170:
            r_minor = 35.0
        elif f107 >= 130:
            r_minor = 25.0
        else:
            r_minor = 15.0
    if r_major is None and r_minor is not None:
        r_major = max(5.0, r_minor * 0.20)
    if s_prob is None and r_major is not None:
        s_prob = max(5.0, r_major)
    if forecast_g is None and ap is not None:
        forecast_g = max(0.0, min(5.0, (ap_to_kp(ap) or 0.0) - 4.0))

    estimated_kp = ap_to_kp(ap)

    if ap is None or f107 is None:
        environment = "Insufficient NOAA forecast data"
    elif ap >= 30:
        environment = "Poor/volatile; strong storm effects"
    elif ap >= 20:
        environment = "Disturbed; expect reduced DX reliability"
    elif ap >= 12:
        environment = "Unsettled; mixed propagation"
    elif f107 >= 170:
        environment = "Quiet enough for strong upper-band potential"
    elif f107 >= 130:
        environment = "Generally favorable middle/high-band potential"
    else:
        environment = "Lower and middle bands favored"

    date_label = (
        "Today " + date_value.strftime("%a %-m/%-d")
        if offset == 0
        else date_value.strftime("%a %-m/%-d")
    )

    estimate_marker = "*" if probability_estimated else ""
    g_text = "N/A" if forecast_g is None else "G" + str(int(round(forecast_g)))
    r_minor_text = "N/A" if r_minor is None else fmt(r_minor, 0, "N/A") + "%" + estimate_marker
    r_major_text = "N/A" if r_major is None else fmt(r_major, 0, "N/A") + "%"
    s_prob_text = "N/A" if s_prob is None else fmt(s_prob, 0, "N/A") + "%"
    print(
        f"  {date_label:<16} "
        f"{fmt(f107, 0, 'N/A'):>7} "
        f"{fmt(ap, 0, 'N/A'):>6} "
        f"{fmt(estimated_kp, 0, 'N/A'):>8} "
        f"{g_text:>4} "
        f"{r_minor_text:>8} "
        f"{r_major_text:>7} "
        f"{s_prob_text:>7}  "
        f"{environment}"
    )

    daily_records.append({
        "date": date_value,
        "f107": f107,
        "ap": ap,
        "r_minor": r_minor,
        "r_major": r_major,
        "s_prob": s_prob,
        "g": forecast_g,
        "probability_estimated": probability_estimated,
    })

print()
print(
    f"  {C.DIM}F10.7 and Ap are NOAA daily forecasts. Estimated Kp is converted "
    f"from daily Ap and is not a NOAA 3-hour Kp forecast. An asterisk marks a "
    f"day beyond NOAA's probability forecast window.{C.RESET}"
)

if rationales:
    print()
    for index, rationale in enumerate(rationales, start=1):
        labels = {
            1: "Geomagnetic: ",
            2: "Solar radiation: ",
            3: "Radio blackout: ",
        }
        wrap_print(labels.get(index, "NOAA: "), rationale)

# Best bands right now
heading("BEST HF BANDS RIGHT NOW")

today_forecast = daily_records[0]
current_f107_for_model = observed_f107 or today_forecast["f107"]
current_ap_for_model = today_forecast["ap"]
if current_ap_for_model is None and current_ap_running is not None:
    # The Kp feed's a_running value is a 3-hour a-index equivalent, not a daily
    # Ap forecast. Cap it when it is the only available geomagnetic input so a
    # single disturbed interval does not unrealistically zero every band.
    current_ap_for_model = min(current_ap_running, 48.0)
current_r_probability = today_forecast["r_minor"]

if (
    current_f107_for_model is None
    or current_ap_for_model is None
    or current_r_probability is None
):
    print("  Current band ranking is unavailable because required NOAA data is missing.")
else:
    current_scores = []
    for band_info in BANDS:
        score = propagation_score(
            band_info["band"],
            current_f107_for_model,
            current_ap_for_model,
            current_r_probability,
            today,
        )
        score *= current_open_factor(
            band_info["band"],
            now_local,
            sunrise_today,
            sunset_today,
        )
        current_scores.append((score, band_info))

    current_scores.sort(key=lambda item: item[0], reverse=True)
    for rank, (score, band_info) in enumerate(current_scores[:5], start=1):
        rating = rating_from_score(score)
        print(
            f"  {rank}. {band_info['band']:<6} "
            f"{band_info['mhz']:>5.1f} MHz  "
            f"{color_rating(rating):<22} "
            f"Score {score:>5.1f}/100  "
            f"{band_info['service']}"
        )

    print()
    print(
        f"  {C.DIM}The right-now ranking combines the daily model with whether each "
        f"band normally favors local daylight or darkness. Actual paths can differ "
        f"because of sporadic-E, gray-line enhancement, local noise, antenna pattern, "
        f"and sudden solar flares.{C.RESET}"
    )

# Four daily band tables
for record in daily_records:
    date_value = record["date"]
    sunrise, sunset = sun_times(date_value)

    heading(
        f"HF PROPAGATION BY BAND: "
        f"{date_value.strftime('%A, %B %-d, %Y')}"
    )
    print(
        f"  Sunrise {clock(sunrise)}  |  Sunset {clock(sunset)}  |  "
        f"F10.7 {fmt(record['f107'], 0, 'N/A')} sfu  |  "
        f"Ap {fmt(record['ap'], 0, 'N/A')}  |  "
        f"R1-R2 chance "
        f"{('N/A' if record['r_minor'] is None else fmt(record['r_minor'], 0, 'N/A') + '%')}"
    )
    print()
    print(
        f"  {'Band':<7} {'Freq':>7}  {'Rating':<10} {'Score':>6}  "
        f"{'Best local operating window':<27}  Forecast notes"
    )
    print("  " + "─" * min(TERM_WIDTH - 2, 132))

    if (
        record["f107"] is None
        or record["ap"] is None
        or record["r_minor"] is None
    ):
        print("  Required NOAA daily forecast data is unavailable for this date.")
        continue

    for band_info in BANDS:
        score = propagation_score(
            band_info["band"],
            record["f107"],
            record["ap"],
            record["r_minor"],
            date_value,
        )
        rating = rating_from_score(score)
        window = band_window(band_info["band"], sunrise, sunset)
        note = band_note(
            band_info["band"],
            score,
            record["f107"],
            record["ap"],
            record["r_minor"],
            date_value,
        )

        # Keep the colored rating from corrupting visual column widths by
        # applying color only after padding.
        rating_padded = f"{rating:<10}"
        rating_colored = color_rating(rating_padded.strip()) + (
            " " * max(0, 10 - len(rating))
        )

        print(
            f"  {band_info['band']:<7} "
            f"{band_info['mhz']:>5.1f}M  "
            f"{rating_colored} "
            f"{score:>5.1f}  "
            f"{window:<27}  "
            f"{note}"
        )

# Method and caveats
heading("FORECAST METHOD AND IMPORTANT LIMITS")
method_text = (
    "NOAA provides measured space-weather conditions and forecasts for solar "
    "radio flux, geomagnetic activity, radio-blackout probability, solar-radiation "
    "storms, and NOAA R/S/G scales. NOAA does not issue a separate amateur-radio "
    "rating for every HF band. The band ratings in this report are therefore local "
    "engineering estimates based on NOAA F10.7, Ap/Kp, radio-blackout probability, "
    "the Sparrow Bush sunrise/sunset cycle, seasonal low-band noise, and typical "
    "day/night behavior for each amateur band."
)
wrap_print("", method_text)

caveat_text = (
    "These ratings describe general regional and DX potential, not a point-to-point "
    "MUF prediction. They cannot account for a specific destination, antenna, power "
    "level, terrain, man-made noise, thunderstorms, sporadic-E, or a solar flare "
    "that occurs after the report is generated."
)
wrap_print("", caveat_text)

print()
print(C.BOLD + C.BLUE + hr("═") + C.RESET)
print(
    C.DIM
    + "Sources: NOAA Space Weather Prediction Center public products and data feeds."
    + C.RESET
)
print(
    C.DIM
    + "Cache: ~/.cache/space_weather_hf_report  |  "
      "Run with --once for cron, logging, or redirected output."
    + C.RESET
)

# Warn about stale/missing feeds
stale_items = []
for key, item in results.items():
    if not item.get("live") and item.get("payload") is not None:
        cached_at = item.get("cached_at")
        cached_text = (
            cached_at.astimezone(TIME_ZONE).strftime("%b %-d %-I:%M %p %Z")
            if isinstance(cached_at, dt.datetime)
            else "unknown time"
        )
        stale_items.append(f"{key} cached {cached_text}")

if stale_items:
    print()
    wrap_print(
        "Cached-data warning: ",
        "; ".join(stale_items),
    )

if missing_count:
    missing_names = [
        key for key, item in results.items()
        if item.get("payload") is None
    ]
    print()
    wrap_print(
        "Unavailable feeds: ",
        ", ".join(missing_names)
        + ". The report continues with the remaining NOAA products.",
    )
PYTHON

    EXIT_STATUS=$?

    if [[ $ONCE -eq 1 ]]; then
        exit "$EXIT_STATUS"
    fi

    echo
    echo "Press R to refresh the report, or press Q/any other key to close."
    IFS= read -r -s -n 1 KEY || true
    echo
    if [[ "${KEY:-}" =~ [Rr] ]]; then
        continue
    fi
    break
done
