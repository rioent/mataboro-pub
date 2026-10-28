#!/usr/bin/env bash
set -euo pipefail

OUTPUT="$HOME/Desktop/sparrowbush_lightning.html"
OPEN_BROWSER=1

show_help() {
  cat <<'EOF'
Sparrowbush lightning HTML output generator

Creates a static HTML lightning report with USGS The National Map tiles for:
34 Whitehead Road, Sparrow Bush, NY 12780

Usage:
  ./sparrowbush_lightning_html_output.sh
  ./sparrowbush_lightning_html_output.sh --output /var/www/html/lightning.html
  ./sparrowbush_lightning_html_output.sh --no-open

Options:
  -o, --output PATH   HTML output file. Default: $HOME/sparrowbush_lightning.html
  --no-open           Do not open the generated HTML file in the browser
  -h, --help          Show this help text

To update a web page every 5 minutes with cron:
  */5 * * * * /full/path/sparrowbush_lightning_html_output.sh --output /var/www/html/lightning.html --no-open >/tmp/sparrowbush_lightning.log 2>&1
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output)
      if [[ $# -lt 2 ]]; then
        echo "Missing output path after $1" >&2
        exit 2
      fi
      OUTPUT="$2"
      shift 2
      ;;
    --no-open)
      OPEN_BROWSER=0
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      OUTPUT="$1"
      shift
      ;;
  esac
done

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required. Install with: sudo apt install python3 python3-venv python3-pip" >&2
  exit 1
fi

CACHE_BASE="${XDG_CACHE_HOME:-$HOME/.cache}/sparrowbush-lightning-html"
VENV="$CACHE_BASE/venv"
PYTHON_APP="$CACHE_BASE/generate_lightning_html.py"
mkdir -p "$CACHE_BASE"

if [[ ! -d "$VENV" ]]; then
  echo "Creating private Python environment..."
  python3 -m venv "$VENV"
fi

PY="$VENV/bin/python"
PIP="$VENV/bin/pip"

if ! "$PY" - <<'PY_CHECK' >/dev/null 2>&1
import netCDF4
PY_CHECK
then
  echo "Installing Python NetCDF reader into private environment..."
  "$PY" -m pip install --upgrade pip >/dev/null
  "$PIP" install netCDF4 >/dev/null
fi

cat > "$PYTHON_APP" <<'PY_APP'
#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import html
import math
import os
import re
import statistics
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Iterable
from zoneinfo import ZoneInfo

from netCDF4 import Dataset

APP_NAME = "Sparrowbush Lightning Dashboard"
ADDRESS = "34 Whitehead Road, Sparrow Bush, NY 12780"
TIMEZONE_NAME = "America/New_York"
LOCAL_TZ = ZoneInfo(TIMEZONE_NAME)
RADIUS_MILES = 100.0
LOOKBACK_MINUTES = 60
REFRESH_SECONDS = 300
GOES_PRIMARY = "19"
GOES_FALLBACK = "18"
GOES_PRODUCT = "GLM-L2-LCFA"
USER_AGENT = "Sparrowbush-Lightning-HTML-USGS/1.1 (personal static dashboard; NOAA and USGS public data)"
APP_DIR = Path(__file__).resolve().parent
CACHE_DIR = Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache"))) / "sparrowbush-lightning-web"
GLM_CACHE_DIR = CACHE_DIR / "glm"
LOCATION_CACHE = CACHE_DIR / "location.json"
FALLBACK_LAT = 41.4100
FALLBACK_LON = -74.7200
CACHE_DIR.mkdir(parents=True, exist_ok=True)
GLM_CACHE_DIR.mkdir(parents=True, exist_ok=True)


def utc_now() -> datetime:
    return datetime.now(timezone.utc).replace(microsecond=0)


def iso_utc(value: datetime | None) -> str | None:
    if value is None:
        return None
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def http_bytes(url: str, *, accept: str = "*/*", timeout: int = 35) -> bytes:
    request = urllib.request.Request(
        url,
        headers={"User-Agent": USER_AGENT, "Accept": accept},
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read()


def http_json(url: str, *, timeout: int = 35) -> Any:
    return json.loads(http_bytes(url, accept="application/json", timeout=timeout).decode("utf-8"))


def geocode_address() -> tuple[float, float, str, str | None]:
    if LOCATION_CACHE.exists():
        try:
            cached = json.loads(LOCATION_CACHE.read_text(encoding="utf-8"))
            if cached.get("address") == ADDRESS:
                return (
                    float(cached["lat"]),
                    float(cached["lon"]),
                    str(cached.get("source", "cached")),
                    None,
                )
        except Exception:
            pass

    params = urllib.parse.urlencode(
        {"address": ADDRESS, "benchmark": "Public_AR_Current", "format": "json"}
    )
    census_url = f"https://geocoding.geo.census.gov/geocoder/locations/onelineaddress?{params}"
    try:
        data = http_json(census_url)
        matches = data.get("result", {}).get("addressMatches", [])
        if matches:
            coordinates = matches[0]["coordinates"]
            lat, lon = float(coordinates["y"]), float(coordinates["x"])
            LOCATION_CACHE.write_text(
                json.dumps({"address": ADDRESS, "lat": lat, "lon": lon, "source": "U.S. Census Geocoder"}),
                encoding="utf-8",
            )
            return lat, lon, "U.S. Census Geocoder", None
    except Exception:
        pass

    # No OpenStreetMap/Nominatim fallback is used in this version. The U.S. Census
    # geocoder is attempted first, then the script falls back to the known local
    # coordinate below so the report can still render without any map/geocoder account.

    return (
        FALLBACK_LAT,
        FALLBACK_LON,
        "built-in Sparrow Bush fallback coordinate",
        "Address geocoding was unavailable; a nearby fallback coordinate is being used.",
    )


def haversine_miles(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    earth_radius_miles = 3958.7613
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = math.radians(lat2 - lat1)
    dl = math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * earth_radius_miles * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def bearing_degrees(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dl = math.radians(lon2 - lon1)
    y = math.sin(dl) * math.cos(p2)
    x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    return (math.degrees(math.atan2(y, x)) + 360) % 360


def cardinal(degrees: float) -> str:
    names = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
    return names[int((degrees + 11.25) // 22.5) % 16]


def sector8(degrees: float) -> str:
    names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
    return names[int((degrees + 22.5) // 45) % 8]


def parse_goes_key_time(key: str) -> datetime | None:
    match = re.search(r"_s(\d{4})(\d{3})(\d{2})(\d{2})(\d{2})(\d)", key)
    if not match:
        return None
    year, day, hour, minute, second, tenth = match.groups()
    base = datetime.strptime(
        f"{year}{day}{hour}{minute}{second}", "%Y%j%H%M%S"
    ).replace(tzinfo=timezone.utc)
    return base + timedelta(milliseconds=int(tenth) * 100)


def parse_seconds_since(units: str, fallback: datetime) -> datetime:
    match = re.search(r"seconds\s+since\s+(.+)", units, flags=re.I)
    if not match:
        return fallback
    text = match.group(1).strip().replace("Z", "+00:00").replace(" UTC", "+00:00")
    try:
        value = datetime.fromisoformat(text)
    except ValueError:
        try:
            value = datetime.strptime(text.split(".")[0], "%Y-%m-%d %H:%M:%S")
        except ValueError:
            return fallback
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


@dataclass(frozen=True)
class Flash:
    timestamp: datetime
    lat: float
    lon: float
    distance_mi: float
    bearing_deg: float
    energy_j: float | None
    area_m2: float | None
    duration_s: float | None
    group_count: int | None
    quality_flag: int | None

    def age_minutes(self, reference: datetime) -> float:
        return max(0.0, (reference - self.timestamp).total_seconds() / 60.0)

    @property
    def area_km2(self) -> float | None:
        return None if self.area_m2 is None else self.area_m2 / 1_000_000.0

    def to_json(self, reference: datetime) -> dict[str, Any]:
        return {
            "time_utc": iso_utc(self.timestamp),
            "time_local": self.timestamp.astimezone(LOCAL_TZ).isoformat(),
            "age_minutes": round(self.age_minutes(reference), 2),
            "lat": round(self.lat, 5),
            "lon": round(self.lon, 5),
            "distance_mi": round(self.distance_mi, 2),
            "bearing_deg": round(self.bearing_deg, 1),
            "bearing": cardinal(self.bearing_deg),
            "energy_j": self.energy_j,
            "area_km2": self.area_km2,
            "duration_s": self.duration_s,
            "group_count": self.group_count,
            "quality_flag": self.quality_flag,
        }


def s3_hour_keys(satellite: str, hour: datetime) -> list[str]:
    prefix = f"{GOES_PRODUCT}/{hour.year:04d}/{hour.timetuple().tm_yday:03d}/{hour.hour:02d}/"
    base = f"https://noaa-goes{satellite}.s3.amazonaws.com/"
    keys: list[str] = []
    continuation: str | None = None
    while True:
        query: dict[str, str] = {"list-type": "2", "prefix": prefix, "max-keys": "1000"}
        if continuation:
            query["continuation-token"] = continuation
        root = ET.fromstring(http_bytes(base + "?" + urllib.parse.urlencode(query), accept="application/xml"))
        keys.extend(element.text for element in root.findall(".//{*}Key") if element.text)
        truncated = (root.findtext(".//{*}IsTruncated") or "false").lower() == "true"
        continuation = root.findtext(".//{*}NextContinuationToken")
        if not truncated or not continuation:
            return keys


def candidate_goes_keys(satellite: str, start: datetime, end: datetime) -> list[str]:
    hour = start.replace(minute=0, second=0, microsecond=0)
    last_hour = end.replace(minute=0, second=0, microsecond=0)
    keys: list[str] = []
    while hour <= last_hour:
        keys.extend(s3_hour_keys(satellite, hour))
        hour += timedelta(hours=1)
    selected: list[tuple[datetime, str]] = []
    for key in keys:
        value = parse_goes_key_time(key)
        if value and start - timedelta(seconds=30) <= value <= end + timedelta(minutes=2):
            selected.append((value, key))
    selected.sort()
    return [key for _, key in selected]


def nc_values(dataset: Dataset, name: str) -> Any:
    variable = dataset.variables.get(name)
    if variable is None:
        return None
    values = variable[:]
    return values.filled(float("nan")) if hasattr(values, "filled") else values


def finite_float(value: Any) -> float | None:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) else None


def parse_glm_file(path: Path, key: str, target_lat: float, target_lon: float, start: datetime, end: datetime) -> list[Flash]:
    key_time = parse_goes_key_time(key) or start
    flashes: list[Flash] = []
    with Dataset(path, mode="r") as dataset:
        lats = nc_values(dataset, "flash_lat")
        lons = nc_values(dataset, "flash_lon")
        first_offsets = nc_values(dataset, "flash_time_offset_of_first_event")
        if lats is None or lons is None or first_offsets is None:
            return flashes
        last_offsets = nc_values(dataset, "flash_time_offset_of_last_event")
        energies = nc_values(dataset, "flash_energy")
        areas = nc_values(dataset, "flash_area")
        groups = nc_values(dataset, "flash_child_group_count")
        quality = nc_values(dataset, "flash_quality_flag")
        units = getattr(dataset.variables["flash_time_offset_of_first_event"], "units", "")
        time_base = parse_seconds_since(str(units), key_time)

        for index in range(len(lats)):
            flash_lat = finite_float(lats[index])
            flash_lon = finite_float(lons[index])
            offset = finite_float(first_offsets[index])
            if flash_lat is None or flash_lon is None or offset is None:
                continue
            timestamp = time_base + timedelta(seconds=offset)
            if timestamp < start or timestamp > end + timedelta(minutes=2):
                continue
            distance = haversine_miles(target_lat, target_lon, flash_lat, flash_lon)
            if distance > RADIUS_MILES:
                continue
            duration = None
            if last_offsets is not None:
                last_offset = finite_float(last_offsets[index])
                if last_offset is not None:
                    duration = max(0.0, last_offset - offset)
            group_count = None
            if groups is not None:
                group_value = finite_float(groups[index])
                group_count = int(group_value) if group_value is not None else None
            quality_flag = None
            if quality is not None:
                quality_value = finite_float(quality[index])
                quality_flag = int(quality_value) if quality_value is not None else None
            flashes.append(
                Flash(
                    timestamp=timestamp,
                    lat=flash_lat,
                    lon=flash_lon,
                    distance_mi=distance,
                    bearing_deg=bearing_degrees(target_lat, target_lon, flash_lat, flash_lon),
                    energy_j=finite_float(energies[index]) if energies is not None else None,
                    area_m2=finite_float(areas[index]) if areas is not None else None,
                    duration_s=duration,
                    group_count=group_count,
                    quality_flag=quality_flag,
                )
            )
    return flashes


def cache_path_for_key(satellite: str, key: str) -> Path:
    return GLM_CACHE_DIR / f"goes{satellite}_{Path(key).name}"


def clean_glm_cache() -> None:
    cutoff = time.time() - 3 * 60 * 60
    for path in GLM_CACHE_DIR.glob("*.nc"):
        try:
            if path.stat().st_mtime < cutoff:
                path.unlink(missing_ok=True)
        except OSError:
            pass


def ensure_glm_file(satellite: str, key: str) -> tuple[Path, bool, int]:
    destination = cache_path_for_key(satellite, key)
    if destination.exists() and destination.stat().st_size > 0:
        return destination, True, destination.stat().st_size
    url = f"https://noaa-goes{satellite}.s3.amazonaws.com/" + urllib.parse.quote(key, safe="/")
    payload = http_bytes(url, accept="application/x-netcdf", timeout=50)
    with tempfile.NamedTemporaryFile(dir=GLM_CACHE_DIR, suffix=".part", delete=False) as temp:
        temp.write(payload)
        temp_path = Path(temp.name)
    temp_path.replace(destination)
    return destination, False, len(payload)


def get_lightning(lat: float, lon: float, now: datetime) -> tuple[list[Flash], str | None, dict[str, Any]]:
    start = now - timedelta(minutes=LOOKBACK_MINUTES)
    metadata: dict[str, Any] = {
        "satellite": None,
        "files_listed": 0,
        "files_cached": 0,
        "files_downloaded": 0,
        "files_parsed": 0,
        "files_failed": 0,
        "bytes_downloaded": 0,
        "latest_file_time": None,
    }
    listing_errors: list[str] = []
    keys: list[str] = []
    satellite = GOES_PRIMARY
    for candidate in (GOES_PRIMARY, GOES_FALLBACK):
        try:
            keys = candidate_goes_keys(candidate, start, now)
        except Exception as exc:
            listing_errors.append(f"GOES-{candidate}: {exc}")
            keys = []
        if keys:
            satellite = candidate
            break
    if not keys:
        detail = "; ".join(listing_errors) if listing_errors else "no recent GLM files were listed"
        return [], f"NOAA GOES GLM data unavailable: {detail}", metadata

    metadata["satellite"] = satellite
    metadata["files_listed"] = len(keys)
    metadata["latest_file_time"] = iso_utc(parse_goes_key_time(keys[-1]))
    flashes: list[Flash] = []
    seen: set[tuple[Any, ...]] = set()

    local_files: list[tuple[str, Path]] = []
    with ThreadPoolExecutor(max_workers=10) as executor:
        future_map = {executor.submit(ensure_glm_file, satellite, key): key for key in keys}
        for future in as_completed(future_map):
            key = future_map[future]
            try:
                path, cached, byte_count = future.result()
                metadata["files_cached" if cached else "files_downloaded"] += 1
                metadata["bytes_downloaded"] += 0 if cached else byte_count
                local_files.append((key, path))
            except Exception:
                metadata["files_failed"] += 1

    # NetCDF4/HDF5 reads are kept on one thread for broad Linux compatibility.
    # File downloads remain parallel, which is the slow part on the initial run.
    local_files.sort(key=lambda item: parse_goes_key_time(item[0]) or start)
    for key, path in local_files:
        try:
            parsed = parse_glm_file(path, key, lat, lon, start, now)
            metadata["files_parsed"] += 1
            for flash in parsed:
                dedupe = (round(flash.timestamp.timestamp(), 3), round(flash.lat, 4), round(flash.lon, 4))
                if dedupe not in seen:
                    seen.add(dedupe)
                    flashes.append(flash)
        except Exception:
            metadata["files_failed"] += 1
    flashes.sort(key=lambda item: item.timestamp, reverse=True)
    clean_glm_cache()
    if metadata["files_parsed"] == 0:
        return [], "GLM files were listed but none could be decoded.", metadata
    return flashes, None, metadata


def get_open_meteo(lat: float, lon: float) -> tuple[dict[str, Any], str | None]:
    current_variables = [
        "temperature_2m", "relative_humidity_2m", "dew_point_2m", "apparent_temperature",
        "precipitation", "rain", "showers", "weather_code", "cloud_cover", "cloud_cover_low",
        "cloud_cover_mid", "cloud_cover_high", "pressure_msl", "surface_pressure", "wind_speed_10m",
        "wind_direction_10m", "wind_gusts_10m", "visibility", "cape", "lifted_index",
        "convective_inhibition", "freezing_level_height", "boundary_layer_height",
        "temperature_850hPa", "dew_point_850hPa", "wind_speed_850hPa", "wind_direction_850hPa",
        "geopotential_height_850hPa", "temperature_700hPa", "dew_point_700hPa", "wind_speed_700hPa",
        "wind_direction_700hPa", "geopotential_height_700hPa", "temperature_500hPa",
        "dew_point_500hPa", "wind_speed_500hPa", "wind_direction_500hPa", "geopotential_height_500hPa",
    ]
    params = urllib.parse.urlencode(
        {
            "latitude": f"{lat:.6f}",
            "longitude": f"{lon:.6f}",
            "current": ",".join(current_variables),
            "temperature_unit": "celsius",
            "wind_speed_unit": "mph",
            "precipitation_unit": "inch",
            "timezone": TIMEZONE_NAME,
        }
    )
    try:
        return http_json(f"https://api.open-meteo.com/v1/gfs?{params}"), None
    except urllib.error.HTTPError as exc:
        return {}, f"Open-Meteo HTTP {exc.code}"
    except Exception as exc:
        return {}, f"Open-Meteo request failed: {exc}"


def get_nws_alerts(lat: float, lon: float) -> tuple[list[dict[str, Any]], str | None]:
    try:
        data = http_json(f"https://api.weather.gov/alerts/active?point={lat:.4f},{lon:.4f}")
        return list(data.get("features", [])), None
    except Exception as exc:
        return [], f"NWS alert request failed: {exc}"


def linear_slope(points: Iterable[tuple[float, float]]) -> float | None:
    pairs = list(points)
    if len(pairs) < 3:
        return None
    xs, ys = [p[0] for p in pairs], [p[1] for p in pairs]
    xbar, ybar = statistics.fmean(xs), statistics.fmean(ys)
    denominator = sum((x - xbar) ** 2 for x in xs)
    if denominator == 0:
        return None
    return sum((x - xbar) * (y - ybar) for x, y in pairs) / denominator


def movement_analysis(flashes: list[Flash], now: datetime) -> dict[str, Any]:
    recent = [f for f in flashes if f.age_minutes(now) <= 20]
    older = [f for f in flashes if 20 < f.age_minutes(now) <= LOOKBACK_MINUTES]
    result: dict[str, Any] = {
        "result": "INSUFFICIENT HISTORY",
        "recent_count": len(recent),
        "older_count": len(older),
        "recent_median_mi": None,
        "older_median_mi": None,
        "change_mi": None,
        "slope_mi_per_min": None,
        "sectors": [],
    }
    if len(recent) >= 2 and len(older) >= 2:
        recent_median = statistics.median(f.distance_mi for f in recent)
        older_median = statistics.median(f.distance_mi for f in older)
        change = recent_median - older_median
        chronological = sorted(flashes, key=lambda f: f.timestamp)
        t0 = chronological[0].timestamp
        slope = linear_slope(((f.timestamp - t0).total_seconds() / 60, f.distance_mi) for f in chronological)
        classification = "MIXED OR NEARLY STATIONARY"
        if change <= -5 and (slope is None or slope < -0.05):
            classification = "GETTING CLOSER"
        elif change >= 5 and (slope is None or slope > 0.05):
            classification = "MOVING AWAY"
        result.update(
            {
                "result": classification,
                "recent_median_mi": round(recent_median, 1),
                "older_median_mi": round(older_median, 1),
                "change_mi": round(change, 1),
                "slope_mi_per_min": None if slope is None else round(slope, 3),
            }
        )
    for sector in ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]:
        recent_distances = [f.distance_mi for f in recent if sector8(f.bearing_deg) == sector]
        older_distances = [f.distance_mi for f in older if sector8(f.bearing_deg) == sector]
        if len(recent_distances) >= 2 and len(older_distances) >= 2:
            recent_median = statistics.median(recent_distances)
            older_median = statistics.median(older_distances)
            change = recent_median - older_median
            trend = "closer" if change <= -5 else "away" if change >= 5 else "mixed/stable"
            result["sectors"].append(
                {
                    "sector": sector,
                    "recent_count": len(recent_distances),
                    "older_count": len(older_distances),
                    "recent_median_mi": round(recent_median, 1),
                    "older_median_mi": round(older_median, 1),
                    "change_mi": round(change, 1),
                    "trend": trend,
                }
            )
    return result


def weather_code_text(code: Any) -> str:
    mapping = {
        0: "Clear", 1: "Mainly clear", 2: "Partly cloudy", 3: "Overcast", 45: "Fog",
        48: "Depositing rime fog", 51: "Light drizzle", 53: "Drizzle", 55: "Dense drizzle",
        61: "Light rain", 63: "Rain", 65: "Heavy rain", 80: "Light rain showers",
        81: "Rain showers", 82: "Violent rain showers", 95: "Thunderstorm",
        96: "Thunderstorm with slight hail", 99: "Thunderstorm with heavy hail",
    }
    try:
        return mapping.get(int(code), f"WMO code {int(code)}")
    except Exception:
        return "Unavailable"


def f_from_c(value: Any) -> float | None:
    return None if value is None else round(float(value) * 9 / 5 + 32, 1)


def feet_from_m(value: Any) -> float | None:
    return None if value is None else round(float(value) * 3.28084)


def inhg_from_hpa(value: Any) -> float | None:
    return None if value is None else round(float(value) * 0.0295299831, 2)


def vector_components(speed: float, direction_from_deg: float) -> tuple[float, float]:
    radians = math.radians(direction_from_deg)
    return -speed * math.sin(radians), -speed * math.cos(radians)


def atmospheric_report(weather: dict[str, Any]) -> dict[str, Any]:
    current = weather.get("current", {})
    report: dict[str, Any] = {
        "valid_time": current.get("time"),
        "condition": weather_code_text(current.get("weather_code")),
        "temperature_c": current.get("temperature_2m"),
        "temperature_f": f_from_c(current.get("temperature_2m")),
        "dew_point_c": current.get("dew_point_2m"),
        "dew_point_f": f_from_c(current.get("dew_point_2m")),
        "apparent_temperature_c": current.get("apparent_temperature"),
        "apparent_temperature_f": f_from_c(current.get("apparent_temperature")),
        "relative_humidity_pct": current.get("relative_humidity_2m"),
        "pressure_msl_hpa": current.get("pressure_msl"),
        "pressure_msl_inhg": inhg_from_hpa(current.get("pressure_msl")),
        "surface_pressure_hpa": current.get("surface_pressure"),
        "surface_pressure_inhg": inhg_from_hpa(current.get("surface_pressure")),
        "precipitation_in": current.get("precipitation"),
        "rain_in": current.get("rain"),
        "showers_in": current.get("showers"),
        "cape_jkg": current.get("cape"),
        "lifted_index_c": current.get("lifted_index"),
        "convective_inhibition_jkg": current.get("convective_inhibition"),
        "freezing_level_m": current.get("freezing_level_height"),
        "freezing_level_ft": feet_from_m(current.get("freezing_level_height")),
        "boundary_layer_height_m": current.get("boundary_layer_height"),
        "boundary_layer_height_ft": feet_from_m(current.get("boundary_layer_height")),
        "cloud_cover_pct": current.get("cloud_cover"),
        "cloud_cover_low_pct": current.get("cloud_cover_low"),
        "cloud_cover_mid_pct": current.get("cloud_cover_mid"),
        "cloud_cover_high_pct": current.get("cloud_cover_high"),
        "visibility_m": current.get("visibility"),
        "visibility_ft": feet_from_m(current.get("visibility")),
        "wind_speed_10m_mph": current.get("wind_speed_10m"),
        "wind_direction_10m_deg": current.get("wind_direction_10m"),
        "wind_gusts_10m_mph": current.get("wind_gusts_10m"),
        "temperature_850hpa_c": current.get("temperature_850hPa"),
        "dew_point_850hpa_c": current.get("dew_point_850hPa"),
        "wind_speed_850hpa_mph": current.get("wind_speed_850hPa"),
        "wind_direction_850hpa_deg": current.get("wind_direction_850hPa"),
        "temperature_700hpa_c": current.get("temperature_700hPa"),
        "dew_point_700hpa_c": current.get("dew_point_700hPa"),
        "wind_speed_700hpa_mph": current.get("wind_speed_700hPa"),
        "wind_direction_700hpa_deg": current.get("wind_direction_700hPa"),
        "temperature_500hpa_c": current.get("temperature_500hPa"),
        "dew_point_500hpa_c": current.get("dew_point_500hPa"),
        "wind_speed_500hpa_mph": current.get("wind_speed_500hPa"),
        "wind_direction_500hpa_deg": current.get("wind_direction_500hPa"),
        "estimated_lcl_m": None,
        "estimated_lcl_ft": None,
        "estimated_wet_bulb_c": None,
        "estimated_wet_bulb_f": None,
        "temperature_dewpoint_spread_c": None,
        "k_index": None,
        "total_totals_index": None,
        "lapse_rate_850_500_c_per_km": None,
        "bulk_shear_10m_500hpa_mph": None,
    }
    temperature = current.get("temperature_2m")
    dewpoint = current.get("dew_point_2m")
    humidity = current.get("relative_humidity_2m")
    if temperature is not None and dewpoint is not None:
        spread = float(temperature) - float(dewpoint)
        lcl_m = max(0.0, 125.0 * spread)
        report.update(
            {
                "temperature_dewpoint_spread_c": round(spread, 1),
                "estimated_lcl_m": round(lcl_m),
                "estimated_lcl_ft": round(lcl_m * 3.28084),
            }
        )
        if humidity is not None:
            rh = max(1.0, min(100.0, float(humidity)))
            temp = float(temperature)
            wet_c = (
                temp * math.atan(0.151977 * math.sqrt(rh + 8.313659))
                + math.atan(temp + rh)
                - math.atan(rh - 1.676331)
                + 0.00391838 * rh ** 1.5 * math.atan(0.023101 * rh)
                - 4.686035
            )
            report["estimated_wet_bulb_c"] = round(wet_c, 1)
            report["estimated_wet_bulb_f"] = f_from_c(wet_c)

    t850, td850 = current.get("temperature_850hPa"), current.get("dew_point_850hPa")
    t700, td700 = current.get("temperature_700hPa"), current.get("dew_point_700hPa")
    t500 = current.get("temperature_500hPa")
    z850, z500 = current.get("geopotential_height_850hPa"), current.get("geopotential_height_500hPa")
    if all(value is not None for value in (t850, td850, t700, td700, t500)):
        report["k_index"] = round((float(t850) - float(t500)) + float(td850) - (float(t700) - float(td700)), 1)
        report["total_totals_index"] = round(float(t850) + float(td850) - 2 * float(t500), 1)
    if all(value is not None for value in (t850, t500, z850, z500)) and float(z500) > float(z850):
        report["lapse_rate_850_500_c_per_km"] = round(
            (float(t850) - float(t500)) / ((float(z500) - float(z850)) / 1000), 2
        )
    values = (
        current.get("wind_speed_10m"), current.get("wind_direction_10m"),
        current.get("wind_speed_500hPa"), current.get("wind_direction_500hPa"),
    )
    if all(value is not None for value in values):
        u1, v1 = vector_components(float(values[0]), float(values[1]))
        u2, v2 = vector_components(float(values[2]), float(values[3]))
        report["bulk_shear_10m_500hpa_mph"] = round(math.hypot(u2 - u1, v2 - v1), 1)
    return report


def lightning_summary(flashes: list[Flash], now: datetime) -> dict[str, Any]:
    nearest = min(flashes, key=lambda f: f.distance_mi) if flashes else None
    latest = max(flashes, key=lambda f: f.timestamp) if flashes else None
    energies = [f.energy_j for f in flashes if f.energy_j is not None]
    areas = [f.area_km2 for f in flashes if f.area_km2 is not None]
    durations = [f.duration_s for f in flashes if f.duration_s is not None]
    groups = [f.group_count for f in flashes if f.group_count is not None]
    status = "NO LIGHTNING DETECTED"
    status_level = "clear"
    if nearest:
        if nearest.distance_mi <= 6:
            status, status_level = "EXTREME PROXIMITY", "danger"
        elif nearest.distance_mi <= 10:
            status, status_level = "DANGEROUSLY CLOSE", "danger"
        elif nearest.distance_mi <= 25:
            status, status_level = "HIGH LIGHTNING PROXIMITY", "warning"
        elif nearest.distance_mi <= 50:
            status, status_level = "ELEVATED LIGHTNING PROXIMITY", "warning"
        else:
            status, status_level = "LIGHTNING IN MONITORING AREA", "watch"
    time_bins = []
    for low, high in [(0, 5), (5, 10), (10, 20), (20, 30), (30, 45), (45, 60)]:
        count = sum(low <= f.age_minutes(now) < high for f in flashes)
        time_bins.append({"label": f"{low}-{high} min", "count": count, "rate_per_min": round(count / (high - low), 2)})
    distance_bins = []
    for low, high in [(0, 5), (5, 10), (10, 25), (25, 50), (50, 75), (75, 100)]:
        distance_bins.append({"label": f"{low}-{high} mi", "count": sum(low <= f.distance_mi < high for f in flashes)})
    last_5 = sum(f.age_minutes(now) < 5 for f in flashes)
    previous_5 = sum(5 <= f.age_minutes(now) < 10 for f in flashes)
    if previous_5 == 0:
        rate_trend = "New activity" if last_5 else "No recent activity"
        rate_change_pct = None
    else:
        rate_change_pct = round(((last_5 - previous_5) / previous_5) * 100, 1)
        rate_trend = f"{rate_change_pct:+.1f}% versus prior 5 minutes"
    return {
        "status": status,
        "status_level": status_level,
        "total_flashes": len(flashes),
        "nearest": None if nearest is None else nearest.to_json(now),
        "latest": None if latest is None else latest.to_json(now),
        "good_quality_count": sum(f.quality_flag in (None, 0) for f in flashes),
        "median_energy_j": None if not energies else statistics.median(energies),
        "max_energy_j": None if not energies else max(energies),
        "median_area_km2": None if not areas else statistics.median(areas),
        "max_area_km2": None if not areas else max(areas),
        "median_duration_s": None if not durations else statistics.median(durations),
        "max_duration_s": None if not durations else max(durations),
        "median_group_count": None if not groups else statistics.median(groups),
        "max_group_count": None if not groups else max(groups),
        "last_5_count": last_5,
        "previous_5_count": previous_5,
        "rate_change_pct": rate_change_pct,
        "rate_trend": rate_trend,
        "time_bins": time_bins,
        "distance_bins": distance_bins,
        "movement": movement_analysis(flashes, now),
    }


def serialize_alerts(features: list[dict[str, Any]]) -> list[dict[str, Any]]:
    alerts = []
    for feature in features:
        properties = feature.get("properties", {})
        alerts.append(
            {
                "event": properties.get("event", "Alert"),
                "headline": properties.get("headline") or "",
                "severity": properties.get("severity", "Unknown"),
                "urgency": properties.get("urgency", "Unknown"),
                "certainty": properties.get("certainty", "Unknown"),
                "effective": properties.get("effective"),
                "expires": properties.get("expires"),
                "description": properties.get("description", ""),
                "instruction": properties.get("instruction", ""),
            }
        )
    return alerts


def build_report() -> dict[str, Any]:
    started = time.monotonic()
    now = utc_now()
    lat, lon, geocoder, geocode_warning = geocode_address()
    with ThreadPoolExecutor(max_workers=3) as executor:
        lightning_future = executor.submit(get_lightning, lat, lon, now)
        weather_future = executor.submit(get_open_meteo, lat, lon)
        alerts_future = executor.submit(get_nws_alerts, lat, lon)
        flashes, lightning_error, lightning_metadata = lightning_future.result()
        weather, weather_error = weather_future.result()
        alert_features, alerts_error = alerts_future.result()
    report = {
        "app": APP_NAME,
        "address": ADDRESS,
        "target": {"lat": lat, "lon": lon, "geocoder": geocoder},
        "radius_miles": RADIUS_MILES,
        "lookback_minutes": LOOKBACK_MINUTES,
        "refresh_seconds": REFRESH_SECONDS,
        "generated_utc": iso_utc(now),
        "generated_local": now.astimezone(LOCAL_TZ).isoformat(),
        "processing_seconds": round(time.monotonic() - started, 2),
        "errors": {
            "geocoding": geocode_warning,
            "lightning": lightning_error,
            "atmosphere": weather_error,
            "alerts": alerts_error,
        },
        "source_metadata": lightning_metadata,
        "lightning": lightning_summary(flashes, now),
        "flashes": [flash.to_json(now) for flash in flashes],
        "atmosphere": {} if weather_error else atmospheric_report(weather),
        "alerts": serialize_alerts(alert_features),
        "notes": [
            "GLM reports satellite-detected total-lightning flash centroids, not guaranteed ground-strike locations.",
            "The free GLM feed does not provide electrical polarity or peak current.",
            "Atmospheric fields are model-derived Open-Meteo GFS/HRRR data, not an on-site weather sounding.",
            "Movement compares flash-centroid distance over time and is not radar storm-cell tracking.",
        ],
    }
    return report




def safe_json(data: dict[str, Any]) -> str:
    text = json.dumps(data, ensure_ascii=False, allow_nan=False, separators=(",", ":"))
    return text.replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026").replace("</", "<\\/")


def h(value: Any) -> str:
    if value is None or value == "":
        return "Unavailable"
    return html.escape(str(value), quote=True)


def fmt_num(value: Any, digits: int = 1, suffix: str = "") -> str:
    if value is None:
        return "Unavailable"
    try:
        number = float(value)
        if not math.isfinite(number):
            return "Unavailable"
        if abs(number) >= 1000 and digits > 0:
            return f"{number:,.{digits}f}{suffix}"
        if digits == 0:
            return f"{number:,.0f}{suffix}"
        return f"{number:,.{digits}f}{suffix}"
    except Exception:
        return h(value)


def format_time(value: Any, tz_name: str = TIMEZONE_NAME, mode: str = "local12") -> str:
    if not value:
        return "Unavailable"
    try:
        text = str(value).replace("Z", "+00:00")
        dt = datetime.fromisoformat(text)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        if mode == "utc":
            return dt.astimezone(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
        local = dt.astimezone(ZoneInfo(tz_name))
        if mode == "local24":
            return local.strftime("%Y-%m-%d %H:%M:%S %Z")
        return local.strftime("%Y-%m-%d %I:%M:%S %p %Z")
    except Exception:
        return h(value)


def table_from_pairs(title: str, pairs: list[tuple[str, Any]]) -> str:
    rows = "".join(f"<tr><th>{h(label)}</th><td>{h(value)}</td></tr>" for label, value in pairs)
    return f"<section class='panel'><h2>{h(title)}</h2><table class='kv'>{rows}</table></section>"


def render_report_html(report: dict[str, Any]) -> str:
    data_json = safe_json(report)
    generated_local = report.get("generated_local")
    generated_utc = report.get("generated_utc")
    lightning = report.get("lightning", {}) if isinstance(report.get("lightning"), dict) else {}
    movement = lightning.get("movement", {}) if isinstance(lightning.get("movement"), dict) else {}
    atmosphere = report.get("atmosphere", {}) if isinstance(report.get("atmosphere"), dict) else {}
    target = report.get("target", {}) if isinstance(report.get("target"), dict) else {}
    errors = report.get("errors", {}) if isinstance(report.get("errors"), dict) else {}
    source_metadata = report.get("source_metadata", {}) if isinstance(report.get("source_metadata"), dict) else {}
    flashes = report.get("flashes", []) if isinstance(report.get("flashes"), list) else []
    alerts = report.get("alerts", []) if isinstance(report.get("alerts"), list) else []

    time_bins = lightning.get("time_bins", []) if isinstance(lightning.get("time_bins"), list) else []
    distance_bins = lightning.get("distance_bins", []) if isinstance(lightning.get("distance_bins"), list) else []
    sectors = movement.get("sectors", []) if isinstance(movement.get("sectors"), list) else []

    def rows_for_bins(items: list[dict[str, Any]], columns: list[str]) -> str:
        if not items:
            return "<tr><td colspan='4'>No data available.</td></tr>"
        rows = []
        for item in items:
            cells = "".join(f"<td>{h(item.get(column))}</td>" for column in columns)
            rows.append(f"<tr>{cells}</tr>")
        return "".join(rows)

    nearest = lightning.get("nearest") or {}
    latest = lightning.get("latest") or {}
    nearest_text = "None"
    if nearest:
        nearest_text = f"{fmt_num(nearest.get('distance_mi'), 2, ' mi')} {h(nearest.get('bearing'))} at {format_time(nearest.get('time_local'))}"
    latest_text = "None"
    if latest:
        latest_text = f"{fmt_num(latest.get('distance_mi'), 2, ' mi')} {h(latest.get('bearing'))} at {format_time(latest.get('time_local'))}"

    summary_html = table_from_pairs("Lightning Summary", [
        ("Status", lightning.get("status")),
        ("Total flashes within 100 miles", lightning.get("total_flashes")),
        ("Nearest flash", nearest_text),
        ("Latest flash", latest_text),
        ("Last 5 minutes", lightning.get("last_5_count")),
        ("Previous 5 minutes", lightning.get("previous_5_count")),
        ("Rate trend", lightning.get("rate_trend")),
        ("Median flash energy", fmt_num(lightning.get("median_energy_j"), 1, " J")),
        ("Max flash energy", fmt_num(lightning.get("max_energy_j"), 1, " J")),
        ("Median footprint area", fmt_num(lightning.get("median_area_km2"), 2, " km²")),
        ("Max footprint area", fmt_num(lightning.get("max_area_km2"), 2, " km²")),
        ("Median duration", fmt_num(lightning.get("median_duration_s"), 3, " sec")),
        ("Max duration", fmt_num(lightning.get("max_duration_s"), 3, " sec")),
        ("Good quality flashes", lightning.get("good_quality_count")),
    ])

    movement_html = table_from_pairs("Closer / Away Movement Analysis", [
        ("Overall result", movement.get("result")),
        ("Recent count, last 20 min", movement.get("recent_count")),
        ("Older count, 20-60 min", movement.get("older_count")),
        ("Recent median distance", fmt_num(movement.get("recent_median_mi"), 1, " mi")),
        ("Older median distance", fmt_num(movement.get("older_median_mi"), 1, " mi")),
        ("Distance change", fmt_num(movement.get("change_mi"), 1, " mi")),
        ("Distance slope", fmt_num(movement.get("slope_mi_per_min"), 3, " mi/min")),
    ])

    atmosphere_html = table_from_pairs("Technical Atmospheric Conditions", [
        ("Condition", atmosphere.get("condition")),
        ("Valid time", atmosphere.get("valid_time")),
        ("Temperature", f"{fmt_num(atmosphere.get('temperature_f'), 1, ' °F')} / {fmt_num(atmosphere.get('temperature_c'), 1, ' °C')}"),
        ("Dew point", f"{fmt_num(atmosphere.get('dew_point_f'), 1, ' °F')} / {fmt_num(atmosphere.get('dew_point_c'), 1, ' °C')}"),
        ("Relative humidity", fmt_num(atmosphere.get("relative_humidity_pct"), 0, "%")),
        ("MSL pressure", f"{fmt_num(atmosphere.get('pressure_msl_inhg'), 2, ' inHg')} / {fmt_num(atmosphere.get('pressure_msl_hpa'), 1, ' hPa')}"),
        ("Surface pressure", f"{fmt_num(atmosphere.get('surface_pressure_inhg'), 2, ' inHg')} / {fmt_num(atmosphere.get('surface_pressure_hpa'), 1, ' hPa')}"),
        ("CAPE", fmt_num(atmosphere.get("cape_jkg"), 0, " J/kg")),
        ("Lifted Index", fmt_num(atmosphere.get("lifted_index_c"), 1, " °C")),
        ("Convective inhibition", fmt_num(atmosphere.get("convective_inhibition_jkg"), 0, " J/kg")),
        ("K Index", fmt_num(atmosphere.get("k_index"), 1)),
        ("Total Totals Index", fmt_num(atmosphere.get("total_totals_index"), 1)),
        ("850-500 mb lapse rate", fmt_num(atmosphere.get("lapse_rate_850_500_c_per_km"), 2, " °C/km")),
        ("10 m to 500 mb bulk shear", fmt_num(atmosphere.get("bulk_shear_10m_500hpa_mph"), 1, " mph")),
        ("Estimated cloud base / LCL", f"{fmt_num(atmosphere.get('estimated_lcl_ft'), 0, ' ft')} / {fmt_num(atmosphere.get('estimated_lcl_m'), 0, ' m')}"),
        ("Freezing level", f"{fmt_num(atmosphere.get('freezing_level_ft'), 0, ' ft')} / {fmt_num(atmosphere.get('freezing_level_m'), 0, ' m')}"),
        ("Boundary layer height", f"{fmt_num(atmosphere.get('boundary_layer_height_ft'), 0, ' ft')} / {fmt_num(atmosphere.get('boundary_layer_height_m'), 0, ' m')}"),
        ("Cloud cover low/mid/high", f"{fmt_num(atmosphere.get('cloud_cover_low_pct'), 0, '%')} / {fmt_num(atmosphere.get('cloud_cover_mid_pct'), 0, '%')} / {fmt_num(atmosphere.get('cloud_cover_high_pct'), 0, '%')}"),
        ("10 m wind", f"{fmt_num(atmosphere.get('wind_speed_10m_mph'), 1, ' mph')} from {fmt_num(atmosphere.get('wind_direction_10m_deg'), 0, '°')}; gust {fmt_num(atmosphere.get('wind_gusts_10m_mph'), 1, ' mph')}"),
        ("850 mb temp/dew/wind", f"{fmt_num(atmosphere.get('temperature_850hpa_c'), 1, ' °C')} / {fmt_num(atmosphere.get('dew_point_850hpa_c'), 1, ' °C')} / {fmt_num(atmosphere.get('wind_speed_850hpa_mph'), 1, ' mph')} from {fmt_num(atmosphere.get('wind_direction_850hpa_deg'), 0, '°')}"),
        ("700 mb temp/dew/wind", f"{fmt_num(atmosphere.get('temperature_700hpa_c'), 1, ' °C')} / {fmt_num(atmosphere.get('dew_point_700hpa_c'), 1, ' °C')} / {fmt_num(atmosphere.get('wind_speed_700hpa_mph'), 1, ' mph')} from {fmt_num(atmosphere.get('wind_direction_700hpa_deg'), 0, '°')}"),
        ("500 mb temp/dew/wind", f"{fmt_num(atmosphere.get('temperature_500hpa_c'), 1, ' °C')} / {fmt_num(atmosphere.get('dew_point_500hpa_c'), 1, ' °C')} / {fmt_num(atmosphere.get('wind_speed_500hpa_mph'), 1, ' mph')} from {fmt_num(atmosphere.get('wind_direction_500hpa_deg'), 0, '°')}"),
    ])

    alert_rows = []
    if alerts:
        for alert in alerts:
            alert_rows.append(
                f"<tr><td>{h(alert.get('event'))}</td><td>{h(alert.get('severity'))}</td>"
                f"<td>{h(alert.get('headline'))}</td><td>{h(alert.get('expires'))}</td></tr>"
            )
    else:
        alert_rows.append("<tr><td colspan='4'>No active NWS alerts for the target point.</td></tr>")
    alerts_html = """
    <section class='panel'><h2>National Weather Service Alerts</h2>
    <table><thead><tr><th>Event</th><th>Severity</th><th>Headline</th><th>Expires</th></tr></thead><tbody>__ROWS__</tbody></table></section>
    """.replace("__ROWS__", "".join(alert_rows))

    error_rows = []
    for name, value in errors.items():
        if value:
            error_rows.append(f"<tr><th>{h(name)}</th><td>{h(value)}</td></tr>")
    errors_html = ""
    if error_rows:
        errors_html = f"<section class='panel warning'><h2>Data Warnings</h2><table class='kv'>{''.join(error_rows)}</table></section>"

    flash_rows = []
    for flash in flashes[:1000]:
        flash_rows.append(
            "<tr>"
            f"<td>{h(format_time(flash.get('time_local')))}</td>"
            f"<td>{h(format_time(flash.get('time_utc'), mode='utc'))}</td>"
            f"<td>{fmt_num(flash.get('age_minutes'), 1)}</td>"
            f"<td>{fmt_num(flash.get('distance_mi'), 2)}</td>"
            f"<td>{h(flash.get('bearing'))}</td>"
            f"<td>{fmt_num(flash.get('lat'), 5)}</td>"
            f"<td>{fmt_num(flash.get('lon'), 5)}</td>"
            f"<td>{fmt_num(flash.get('energy_j'), 1)}</td>"
            f"<td>{fmt_num(flash.get('area_km2'), 3)}</td>"
            f"<td>{fmt_num(flash.get('duration_s'), 3)}</td>"
            f"<td>{h(flash.get('group_count'))}</td>"
            f"<td>{h(flash.get('quality_flag'))}</td>"
            "</tr>"
        )
    if not flash_rows:
        flash_rows.append("<tr><td colspan='12'>No GLM flashes were detected within 100 miles during the lookback window.</td></tr>")
    flashes_html = f"""
    <section class='panel full'><h2>Flash Detail Table</h2>
    <p class='small'>Table is capped at 1,000 rows for browser performance. Full data is embedded in the JSON block at the bottom.</p>
    <div class='table-wrap'><table><thead><tr>
    <th>Local Time</th><th>UTC Time</th><th>Age min</th><th>Distance mi</th><th>Bearing</th><th>Lat</th><th>Lon</th><th>Energy J</th><th>Area km²</th><th>Duration s</th><th>Groups</th><th>Quality</th>
    </tr></thead><tbody>{''.join(flash_rows)}</tbody></table></div></section>
    """

    sector_rows = []
    if sectors:
        for item in sectors:
            sector_rows.append(
                f"<tr><td>{h(item.get('sector'))}</td><td>{h(item.get('trend'))}</td>"
                f"<td>{h(item.get('recent_count'))}</td><td>{h(item.get('older_count'))}</td>"
                f"<td>{fmt_num(item.get('recent_median_mi'), 1)}</td><td>{fmt_num(item.get('older_median_mi'), 1)}</td>"
                f"<td>{fmt_num(item.get('change_mi'), 1)}</td></tr>"
            )
    else:
        sector_rows.append("<tr><td colspan='7'>Insufficient sector history.</td></tr>")
    sectors_html = f"""
    <section class='panel'><h2>Movement by Compass Sector</h2>
    <table><thead><tr><th>Sector</th><th>Trend</th><th>Recent</th><th>Older</th><th>Recent Median mi</th><th>Older Median mi</th><th>Change mi</th></tr></thead><tbody>{''.join(sector_rows)}</tbody></table></section>
    """

    bins_html = f"""
    <section class='panel'><h2>Flash Counts by Time</h2>
    <table><thead><tr><th>Age Bin</th><th>Count</th><th>Rate/min</th></tr></thead><tbody>{rows_for_bins(time_bins, ['label','count','rate_per_min'])}</tbody></table></section>
    <section class='panel'><h2>Flash Counts by Distance</h2>
    <table><thead><tr><th>Distance Bin</th><th>Count</th></tr></thead><tbody>{rows_for_bins(distance_bins, ['label','count'])}</tbody></table></section>
    """

    metadata_html = table_from_pairs("Source / Processing Metadata", [
        ("Target coordinate", f"{fmt_num(target.get('lat'), 5)}, {fmt_num(target.get('lon'), 5)}"),
        ("Geocoder", target.get("geocoder")),
        ("Satellite", source_metadata.get("satellite")),
        ("GLM files listed", source_metadata.get("files_listed")),
        ("GLM files parsed", source_metadata.get("files_parsed")),
        ("Files downloaded", source_metadata.get("files_downloaded")),
        ("Files cached", source_metadata.get("files_cached")),
        ("Files failed", source_metadata.get("files_failed")),
        ("Latest GLM file time", source_metadata.get("latest_file_time")),
        ("Processing seconds", report.get("processing_seconds")),
    ])

    notes = report.get("notes", []) if isinstance(report.get("notes"), list) else []
    notes_html = "".join(f"<li>{h(note)}</li>" for note in notes)

    return f"""<!doctype html>
<html lang='en'>
<head>
<meta charset='utf-8'>
<meta name='viewport' content='width=device-width, initial-scale=1'>
<meta http-equiv='refresh' content='{int(report.get('refresh_seconds') or 300)}'>
<title>Sparrowbush Lightning HTML Report - USGS Map</title>
<link rel='stylesheet' href='https://unpkg.com/leaflet@1.9.4/dist/leaflet.css'>
<style>
:root {{ color-scheme: dark; --bg:#07111f; --panel:#0f1d2e; --panel2:#13263d; --text:#e9f2ff; --muted:#9db1cc; --border:#274260; --accent:#74b9ff; --warn:#ffcc66; --danger:#ff6b6b; --ok:#8ce99a; }}
* {{ box-sizing:border-box; }}
body {{ margin:0; background:var(--bg); color:var(--text); font-family:Arial, Helvetica, sans-serif; line-height:1.45; }}
header {{ padding:24px 28px 10px; border-bottom:1px solid var(--border); background:linear-gradient(180deg,#0b1b31,#07111f); }}
h1 {{ margin:0 0 8px; font-size:28px; }}
.subtitle {{ color:var(--muted); margin:0 0 12px; }}
.clock-grid {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(220px,1fr)); gap:12px; margin-top:16px; }}
.clock {{ background:var(--panel); border:1px solid var(--border); border-radius:12px; padding:14px; }}
.clock .label {{ color:var(--muted); font-size:13px; text-transform:uppercase; letter-spacing:.05em; }}
.clock .value {{ font-size:20px; font-weight:700; margin-top:4px; }}
main {{ padding:18px 24px 36px; }}
.status-card {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(190px,1fr)); gap:12px; margin-bottom:16px; }}
.metric {{ background:var(--panel2); border:1px solid var(--border); border-radius:12px; padding:14px; }}
.metric .label {{ color:var(--muted); font-size:13px; }}
.metric .value {{ font-size:24px; font-weight:700; margin-top:4px; }}
#map {{ height:560px; width:100%; border:1px solid var(--border); border-radius:14px; margin:10px 0 20px; background:#1b2737; }}
.grid {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(360px,1fr)); gap:16px; }}
.panel {{ background:var(--panel); border:1px solid var(--border); border-radius:14px; padding:16px; overflow:hidden; }}
.panel.full {{ grid-column:1 / -1; }}
.panel.warning {{ border-color:var(--warn); }}
h2 {{ font-size:18px; margin:0 0 12px; }}
table {{ width:100%; border-collapse:collapse; font-size:14px; }}
th,td {{ border-bottom:1px solid var(--border); padding:8px 9px; vertical-align:top; text-align:left; }}
thead th {{ color:#cde2ff; background:#10233a; position:sticky; top:0; }}
table.kv th {{ width:44%; color:var(--muted); font-weight:600; }}
.table-wrap {{ overflow:auto; max-height:620px; border:1px solid var(--border); border-radius:10px; }}
.small {{ color:var(--muted); font-size:13px; }}
.legend {{ display:flex; flex-wrap:wrap; gap:10px; color:var(--muted); font-size:13px; margin:8px 0 16px; }}
.dot {{ width:12px; height:12px; display:inline-block; border-radius:999px; margin-right:4px; vertical-align:-1px; }}
pre {{ white-space:pre-wrap; word-break:break-word; background:#050b14; border:1px solid var(--border); border-radius:12px; padding:12px; max-height:360px; overflow:auto; }}
ul {{ margin-top:8px; color:var(--muted); }}
a {{ color:var(--accent); }}
</style>
</head>
<body>
<header>
<h1>Sparrowbush Lightning HTML Report - USGS Map</h1>
<p class='subtitle'>{h(report.get('address'))} | {fmt_num(report.get('radius_miles'),0)} mile radius | Previous {h(report.get('lookback_minutes'))} minutes</p>
<div class='clock-grid'>
  <div class='clock'><div class='label'>Local Time</div><div class='value'>{h(format_time(generated_local, mode='local12'))}</div></div>
  <div class='clock'><div class='label'>24 Hour Local Time</div><div class='value'>{h(format_time(generated_local, mode='local24'))}</div></div>
  <div class='clock'><div class='label'>UTC Time</div><div class='value'>{h(format_time(generated_utc, mode='utc'))}</div></div>
</div>
<p class='small'>The page auto-reloads every five minutes. For new data, run this script every five minutes with cron or a systemd timer so the HTML file is refreshed before the browser reloads.</p>
</header>
<main>
<section class='status-card'>
  <div class='metric'><div class='label'>Lightning Status</div><div class='value'>{h(lightning.get('status'))}</div></div>
  <div class='metric'><div class='label'>Flashes Within 100 Miles</div><div class='value'>{h(lightning.get('total_flashes'))}</div></div>
  <div class='metric'><div class='label'>Movement</div><div class='value'>{h(movement.get('result'))}</div></div>
  <div class='metric'><div class='label'>Latest Flash</div><div class='value'>{h(latest_text)}</div></div>
</section>
<h2>100 Mile Lightning Map - USGS The National Map</h2>
<div class='legend'><span><i class='dot' style='background:#ff3b30'></i>0-5 min</span><span><i class='dot' style='background:#ff9500'></i>5-15 min</span><span><i class='dot' style='background:#ffd60a'></i>15-30 min</span><span><i class='dot' style='background:#64d2ff'></i>30-60 min</span></div>
<div id='map'></div>
<p class='small'>Base map source: USGS The National Map USGSTopo tile cache. No OpenStreetMap standard tile server is used.</p>
{errors_html}
<div class='grid'>
{summary_html}
{movement_html}
{bins_html}
{sectors_html}
{atmosphere_html}
{alerts_html}
{metadata_html}
<section class='panel'><h2>Important Notes</h2><ul>{notes_html}</ul></section>
{flashes_html}
<section class='panel full'><h2>Embedded JSON Data</h2><pre id='json-display'></pre></section>
</div>
</main>
<script src='https://unpkg.com/leaflet@1.9.4/dist/leaflet.js'></script>
<script id='report-data' type='application/json'>{data_json}</script>
<script>
const report = JSON.parse(document.getElementById('report-data').textContent);
document.getElementById('json-display').textContent = JSON.stringify(report, null, 2);
function colorForAge(age) {{
  if (age <= 5) return '#ff3b30';
  if (age <= 15) return '#ff9500';
  if (age <= 30) return '#ffd60a';
  return '#64d2ff';
}}
function initMap() {{
  const target = report.target || {{lat: 41.41, lon: -74.72}};
  const map = L.map('map').setView([target.lat, target.lon], 8);
  L.tileLayer('https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer/tile/{{z}}/{{y}}/{{x}}', {{
    maxZoom: 16,
    attribution: 'Map data: U.S. Geological Survey, National Geospatial Program | USGS The National Map'
  }}).addTo(map);
  L.marker([target.lat, target.lon]).addTo(map).bindPopup('<b>Target</b><br>' + report.address);
  L.circle([target.lat, target.lon], {{
    radius: (report.radius_miles || 100) * 1609.344,
    color: '#74b9ff',
    weight: 2,
    fillOpacity: 0.04
  }}).addTo(map);
  const flashes = report.flashes || [];
  const bounds = L.latLngBounds([[target.lat, target.lon]]);
  flashes.forEach(f => {{
    const age = Number(f.age_minutes || 0);
    const marker = L.circleMarker([f.lat, f.lon], {{
      radius: age <= 5 ? 7 : age <= 15 ? 6 : age <= 30 ? 5 : 4,
      color: colorForAge(age),
      fillColor: colorForAge(age),
      fillOpacity: 0.85,
      weight: 1
    }}).addTo(map);
    marker.bindPopup(`<b>NOAA GLM Flash</b><br>Age: ${{f.age_minutes}} min<br>Distance: ${{f.distance_mi}} mi ${{f.bearing}}<br>Energy: ${{f.energy_j ?? 'n/a'}} J<br>Area: ${{f.area_km2 ?? 'n/a'}} km²<br>UTC: ${{f.time_utc}}`);
    bounds.extend([f.lat, f.lon]);
  }});
  if (flashes.length) map.fitBounds(bounds.pad(0.15));
}}
initMap();
</script>
</body>
</html>"""


def write_error_html(output: Path, exc: BaseException) -> None:
    now = utc_now()
    payload = f"""<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width, initial-scale=1'><title>Sparrowbush Lightning Report Error</title><style>body{{font-family:Arial;background:#07111f;color:#e9f2ff;padding:24px}}pre{{background:#050b14;padding:16px;border:1px solid #274260;border-radius:10px;white-space:pre-wrap}}</style></head><body><h1>Sparrowbush Lightning Report Error</h1><p>UTC: {h(iso_utc(now))}</p><p>The HTML report could not be generated.</p><pre>{h(str(exc))}</pre></body></html>"""
    output.write_text(payload, encoding="utf-8")


def html_output_main() -> None:
    parser = argparse.ArgumentParser(description="Generate a static HTML lightning report for 34 Whitehead Road, Sparrow Bush, NY.")
    parser.add_argument("--output", "-o", default=str(Path.home() / "sparrowbush_lightning.html"), help="Output HTML file path")
    args = parser.parse_args()
    output = Path(args.output).expanduser().resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    try:
        report = build_report()
        output.write_text(render_report_html(report), encoding="utf-8")
    except Exception as exc:
        write_error_html(output, exc)
        raise
    print(output)


if __name__ == "__main__":
    html_output_main()

PY_APP

mkdir -p "$(dirname "$OUTPUT")"
echo "Generating lightning HTML report..."
HTML_PATH="$($PY "$PYTHON_APP" --output "$OUTPUT")"
echo "Created: $HTML_PATH"

if [[ "$OPEN_BROWSER" -eq 1 ]]; then
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$HTML_PATH" >/dev/null 2>&1 &
  elif command -v gio >/dev/null 2>&1; then
    gio open "$HTML_PATH" >/dev/null 2>&1 &
  else
    echo "Open this file in your browser: $HTML_PATH"
  fi
fi
