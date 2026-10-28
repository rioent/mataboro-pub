#!/usr/bin/env bash
set -u

# ham_radio_news.sh
# Aggregates the latest 5 ham radio articles from 10 ham radio news sources.
# Displays "Loading Please be Patient" while building the report.
# Opens the report at the top using less.
# Keeps the terminal window open after completion.
#
# Requires:
#   bash
#   python3
#   less
#
# Make executable:
#   chmod +x ham_radio_news.sh
#
# Run:
#   ./ham_radio_news.sh
#
# Inside the report viewer:
# Space = next page
# b     = previous page
# g     = top
# G     = bottom
# q     = quit

REPORT_FILE="$(mktemp /tmp/ham_radio_news.XXXXXX.txt)"

cleanup() {
    rm -f "$REPORT_FILE"
}
trap cleanup EXIT

press_any_key_to_close() {
    echo
    echo "Press any key to close..."

    if [ -r /dev/tty ]; then
        read -n 1 -s -r < /dev/tty
    else
        read -n 1 -s -r
    fi

    echo
}

clear
echo "=============================================="
echo "Loading Please be Patient"
echo "=============================================="
echo
echo "Gathering ham radio news articles..."
echo

if ! command -v python3 >/dev/null 2>&1; then
    clear
    echo "python3 is required but was not found."
    press_any_key_to_close
    exit 1
fi

if ! command -v less >/dev/null 2>&1; then
    clear
    echo "less is required but was not found."
    echo
    echo "Install it with:"
    echo "  sudo apt install less"
    press_any_key_to_close
    exit 1
fi

python3 - <<'PY' > "$REPORT_FILE"
import datetime
import html
import json
import re
import urllib.error
import urllib.parse
import urllib.request
from html.parser import HTMLParser
from xml.etree import ElementTree as ET

try:
    from zoneinfo import ZoneInfo
except Exception:
    ZoneInfo = None


ARTICLES_PER_SITE = 5

SOURCES = [
    {
        "name": "ARRL News",
        "home": "https://www.arrl.org/news",
        "feeds": [
            "https://www.arrl.org/news/rss",
            "https://www.arrl.org/rss/news",
        ],
    },
    {
        "name": "Amateur Radio Newsline",
        "home": "https://www.arnewsline.org/",
        "feeds": [
            "https://www.arnewsline.org/?format=rss",
        ],
    },
    {
        "name": "QRZ Amateur Radio News",
        "home": "https://forums.qrz.com/index.php?forums/amateur-radio-news.9/",
        "feeds": [
            "https://forums.qrz.com/index.php?forums/amateur-radio-news.9/index.rss",
            "https://forums.qrz.com/index.php?forums/-/index.rss",
        ],
    },
    {
        "name": "Amateur Radio Daily",
        "home": "https://daily.hamweekly.com/",
        "feeds": [
            "https://daily.hamweekly.com/rss/",
            "https://daily.hamweekly.com/feed/",
            "https://daily.hamweekly.com/feed.xml",
            "https://daily.hamweekly.com/rss.xml",
            "https://daily.hamweekly.com/index.xml",
        ],
    },
    {
        "name": "Amateur Radio Weekly",
        "home": "https://hamweekly.com/",
        "feeds": [
            "https://hamweekly.com/rss/",
            "https://hamweekly.com/feed/",
            "https://hamweekly.com/feed.xml",
            "https://hamweekly.com/rss.xml",
            "https://hamweekly.com/index.xml",
        ],
    },
    {
        "name": "DX-World",
        "home": "https://www.dx-world.net/",
        "feeds": [
            "https://www.dx-world.net/feed/",
            "https://www.dx-world.net/category/dx-news/feed/",
        ],
    },
    {
        "name": "The Daily DX",
        "home": "https://www.dailydx.com/",
        "feeds": [
            "https://www.dailydx.com/feed/",
            "https://www.dailydx.com/rss/",
            "https://www.dailydx.com/rss.xml",
        ],
    },
    {
        "name": "RSGB News",
        "home": "https://rsgb.org/main/news/",
        "feeds": [
            "https://rsgb.org/main/feed/",
            "https://rsgb.org/main/news/feed/",
        ],
    },
    {
        "name": "IARU News",
        "home": "https://www.iaru.org/news/",
        "feeds": [
            "https://www.iaru.org/feed/",
            "https://www.iaru.org/news/feed/",
        ],
    },
    {
        "name": "This Week in Amateur Radio",
        "home": "https://twiar.net/",
        "feeds": [
            "https://twiar.net/?feed=rss2",
            "https://www.twiar.net/?feed=rss2",
        ],
    },
]


USER_AGENT = (
    "Mozilla/5.0 (X11; Linux x86_64) "
    "AppleWebKit/537.36 ham-radio-news-script/1.0"
)

TAG_RE = re.compile(r"<[^>]+>")
SPACE_RE = re.compile(r"\s+")


def clean_text(value):
    if value is None:
        return ""

    value = str(value)
    value = html.unescape(value)
    value = TAG_RE.sub("", value)
    value = SPACE_RE.sub(" ", value)

    return value.strip()


def fetch_url(url, timeout=15):
    headers = {
        "User-Agent": USER_AGENT,
        "Accept": (
            "application/rss+xml, application/atom+xml, application/xml, "
            "text/xml, application/json, text/html;q=0.9, */*;q=0.8"
        ),
    }

    req = urllib.request.Request(url, headers=headers)

    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            raw = response.read(3_000_000)
            final_url = response.geturl()
            content_type = response.headers.get("content-type", "")

            charset = "utf-8"
            match = re.search(r"charset=([\w\-.]+)", content_type, re.I)

            if match:
                charset = match.group(1)

            try:
                text = raw.decode(charset, errors="replace")
            except Exception:
                text = raw.decode("utf-8", errors="replace")

            return text, final_url, content_type, None

    except urllib.error.HTTPError as exc:
        return "", url, "", f"HTTP {exc.code}"
    except urllib.error.URLError as exc:
        return "", url, "", f"URL error: {exc.reason}"
    except Exception as exc:
        return "", url, "", f"{type(exc).__name__}: {exc}"


def local_name(tag):
    return tag.rsplit("}", 1)[-1].lower()


def child_text(element, names):
    names = {name.lower() for name in names}

    for child in list(element):
        if local_name(child.tag) in names:
            text = clean_text(child.text)

            if text:
                return text

    return ""


def absolutize(url, base_url):
    if not url:
        return ""

    url = html.unescape(url.strip())

    if url.startswith("//"):
        url = "https:" + url

    return urllib.parse.urljoin(base_url, url)


def normalize_url(url):
    try:
        parsed = urllib.parse.urlsplit(url)
        parsed = parsed._replace(fragment="")
        return urllib.parse.urlunsplit(parsed)
    except Exception:
        return url


def parse_json_feed(text, base_url):
    items = []

    try:
        data = json.loads(text)
    except Exception:
        return items

    for item in data.get("items", []):
        title = clean_text(item.get("title") or item.get("summary") or "")
        url = item.get("url") or item.get("external_url") or ""
        date = item.get("date_published") or item.get("date_modified") or ""

        url = absolutize(url, base_url)

        if title and url:
            items.append(
                {
                    "title": title,
                    "url": url,
                    "date": clean_text(date),
                }
            )

    return items


def parse_xml_feed(text, base_url):
    items = []

    try:
        root = ET.fromstring(text.encode("utf-8", errors="ignore"))
    except Exception:
        return items

    rss_items = [
        element for element in root.iter()
        if local_name(element.tag) == "item"
    ]

    for item in rss_items:
        title = child_text(item, ["title"])
        link = child_text(item, ["link"])
        date = child_text(item, ["pubDate", "date", "updated", "published"])

        if not link:
            guid = child_text(item, ["guid"])

            if guid.startswith("http"):
                link = guid

        link = absolutize(link, base_url)

        if title and link:
            items.append(
                {
                    "title": title,
                    "url": link,
                    "date": date,
                }
            )

    if items:
        return items

    atom_entries = [
        element for element in root.iter()
        if local_name(element.tag) == "entry"
    ]

    for entry in atom_entries:
        title = child_text(entry, ["title"])
        link = ""
        date = child_text(entry, ["updated", "published"])

        for child in list(entry):
            if local_name(child.tag) == "link":
                rel = child.attrib.get("rel", "alternate")
                href = child.attrib.get("href", "")

                if href and rel in ("alternate", "", "self"):
                    link = href

                    if rel == "alternate":
                        break

        link = absolutize(link, base_url)

        if title and link:
            items.append(
                {
                    "title": title,
                    "url": link,
                    "date": date,
                }
            )

    return items


def parse_feed(text, base_url):
    if not text.strip():
        return []

    stripped = text.lstrip()

    if stripped.startswith("{"):
        items = parse_json_feed(text, base_url)
    else:
        items = parse_xml_feed(text, base_url)

    return dedupe_items(items)


class FeedDiscoveryParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.feeds = []

    def handle_starttag(self, tag, attrs):
        if tag.lower() != "link":
            return

        attr = {k.lower(): (v or "") for k, v in attrs if k}
        href = attr.get("href", "")
        rel = attr.get("rel", "").lower()
        typ = attr.get("type", "").lower()

        if not href:
            return

        looks_like_feed = (
            "alternate" in rel
            and (
                "rss" in typ
                or "atom" in typ
                or "json" in typ
                or href.endswith(".xml")
                or "feed" in href.lower()
                or "rss" in href.lower()
            )
        )

        if looks_like_feed:
            self.feeds.append(href)


class ArticleLinkParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.current = None
        self.links = []

    def handle_starttag(self, tag, attrs):
        if tag.lower() != "a" or self.current is not None:
            return

        attr = {k.lower(): (v or "") for k, v in attrs if k}
        href = attr.get("href", "")

        if href:
            self.current = {"href": href, "text": []}

    def handle_data(self, data):
        if self.current is not None:
            self.current["text"].append(data)

    def handle_endtag(self, tag):
        if tag.lower() != "a" or self.current is None:
            return

        text = clean_text(" ".join(self.current["text"]))
        href = self.current["href"]

        if text and href:
            self.links.append((text, href))

        self.current = None


def discover_feeds(home_url, explicit_feeds):
    candidates = list(explicit_feeds)

    home_text, final_url, _, _ = fetch_url(home_url)

    if home_text:
        parser = FeedDiscoveryParser()

        try:
            parser.feed(home_text)

            for href in parser.feeds:
                candidates.append(absolutize(href, final_url))
        except Exception:
            pass

    common_paths = [
        "feed/",
        "rss/",
        "feed.xml",
        "rss.xml",
        "atom.xml",
        "index.xml",
        "?feed=rss2",
        "?format=rss",
    ]

    for path in common_paths:
        candidates.append(urllib.parse.urljoin(home_url, path))

    seen = set()
    unique = []

    for url in candidates:
        url = normalize_url(absolutize(url, home_url))

        if url and url not in seen:
            seen.add(url)
            unique.append(url)

    return unique


SKIP_EXACT = {
    "home",
    "about",
    "archive",
    "archives",
    "tags",
    "tag",
    "links",
    "rss",
    "feed",
    "newsletter",
    "submit",
    "contact",
    "contact us",
    "privacy",
    "privacy policy",
    "terms",
    "terms of use",
    "cookies",
    "login",
    "log in",
    "sign in",
    "register",
    "forums",
    "forum",
    "callsign lookup",
    "read more",
    "learn more",
    "next",
    "previous",
}


def bad_title(title):
    low = title.lower().strip(" -|»›")

    if len(low) < 8:
        return True

    if low in SKIP_EXACT:
        return True

    bad_phrases = [
        "cookie",
        "privacy",
        "terms",
        "advertise",
        "sponsor",
        "forgot your password",
        "create account",
        "sign up",
        "log in",
        "login",
        "register",
        "shopping cart",
        "search",
        "site map",
        "copyright",
        "facebook",
        "youtube",
        "twitter",
        "instagram",
        "linkedin",
    ]

    return any(phrase in low for phrase in bad_phrases)


def parse_html_articles(text, base_url):
    parser = ArticleLinkParser()

    try:
        parser.feed(text)
    except Exception:
        return []

    base_host = urllib.parse.urlsplit(base_url).netloc.lower()
    items = []

    for title, href in parser.links:
        title = clean_text(title)

        if bad_title(title):
            continue

        url = absolutize(href, base_url)
        parsed = urllib.parse.urlsplit(url)

        if parsed.scheme not in ("http", "https"):
            continue

        if parsed.netloc.lower() != base_host:
            continue

        low_url = url.lower()

        if any(x in low_url for x in [
            "/login",
            "/register",
            "/privacy",
            "/terms",
            "/contact",
            "/cart",
            "/account",
            "mailto:",
            "javascript:",
        ]):
            continue

        items.append(
            {
                "title": title,
                "url": normalize_url(url),
                "date": "",
            }
        )

    return dedupe_items(items)


def dedupe_items(items):
    seen_urls = set()
    seen_titles = set()
    clean_items = []

    for item in items:
        title = clean_text(item.get("title", ""))
        url = normalize_url(item.get("url", ""))
        date = clean_text(item.get("date", ""))

        if not title or not url:
            continue

        title_key = title.lower()
        url_key = url.lower()

        if url_key in seen_urls or title_key in seen_titles:
            continue

        seen_urls.add(url_key)
        seen_titles.add(title_key)

        clean_items.append(
            {
                "title": title,
                "url": url,
                "date": date,
            }
        )

    return clean_items


def get_articles(source):
    errors = []

    for feed_url in discover_feeds(source["home"], source.get("feeds", [])):
        text, final_url, content_type, error = fetch_url(feed_url)

        if error:
            errors.append(f"{feed_url}: {error}")
            continue

        items = parse_feed(text, final_url)

        if items:
            return items[:ARTICLES_PER_SITE], f"feed: {final_url}", errors

    text, final_url, content_type, error = fetch_url(source["home"])

    if error:
        errors.append(f"{source['home']}: {error}")
        return [], "none", errors

    items = parse_html_articles(text, final_url)

    if items:
        return items[:ARTICLES_PER_SITE], f"page scrape: {final_url}", errors

    return [], "none", errors


def print_header():
    now_utc = datetime.datetime.now(datetime.timezone.utc)

    if ZoneInfo:
        eastern = now_utc.astimezone(ZoneInfo("America/New_York"))
    else:
        eastern = datetime.datetime.now()

    print("=" * 78)
    print("ham radio news")
    print("=" * 78)
    print(f"UTC time     : {now_utc.strftime('%Y-%m-%d %H:%M:%S UTC')}")
    print(f"EST/EDT time : {eastern.strftime('%Y-%m-%d %I:%M:%S %p %Z')}")
    print(f"Date         : {eastern.strftime('%A, %B %d, %Y')}")
    print("=" * 78)


def main():
    print_header()

    for source_number, source in enumerate(SOURCES, start=1):
        print()
        print(f"{source_number}. {source['name']}")
        print("-" * 78)

        articles, method, errors = get_articles(source)

        if not articles:
            print("No public articles found from this source.")

            if errors:
                print(f"Last issue: {errors[-1]}")

            continue

        print(f"Source method: {method}")
        print()

        for item_number, article in enumerate(articles, start=1):
            title = article["title"]
            url = article["url"]
            date = article.get("date", "")

            print(f"{item_number}. {title}")

            if date:
                print(f"   Date: {date}")

            print(f"   Link: {url}")
            print()

    print()
    print("=" * 78)
    print("End of ham radio news")
    print("=" * 78)


if __name__ == "__main__":
    main()
PY

clear

# Open report at the top of the page.
# Navigation:
#   Space = next page
#   b     = previous page
#   g     = top
#   G     = bottom
#   q     = quit report view
less -R "$REPORT_FILE"

clear

echo "ham radio news report closed."
press_any_key_to_close

exit 0