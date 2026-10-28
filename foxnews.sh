#!/usr/bin/env bash

# Fox News Terminal Headlines
# Requires: curl, python3

clear

python3 << 'PY'
import urllib.request
import xml.etree.ElementTree as ET
from html import unescape

feeds = {
    "WORLD NEWS": "https://moxie.foxnews.com/google-publisher/world.xml",
    "U.S. NEWS": "https://moxie.foxnews.com/google-publisher/us.xml",
    "COMPUTER SECURITY NEWS": "https://moxie.foxnews.com/google-publisher/tech.xml",
}

security_words = [
    "cyber", "security", "hack", "hacker", "malware", "ransomware",
    "breach", "password", "privacy", "scam", "phishing", "data"
]

def fetch_feed(url):
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "Mozilla/5.0"}
    )

    with urllib.request.urlopen(req, timeout=15) as response:
        data = response.read()

    root = ET.fromstring(data)
    items = []

    for item in root.findall(".//item"):
        title = item.findtext("title", "").strip()
        link = item.findtext("link", "").strip()

        if title and link:
            items.append((unescape(title), link))

    return items

def print_section(title, items):
    print("=" * 80)
    print(title)
    print("=" * 80)

    if not items:
        print("No headlines found.\n")
        return

    for i, (headline, link) in enumerate(items[:5], start=1):
        print(f"{i}. {headline}")
        print(f"   {link}\n")

try:
    world = fetch_feed(feeds["WORLD NEWS"])[:5]
    us = fetch_feed(feeds["U.S. NEWS"])[:5]

    tech = fetch_feed(feeds["COMPUTER SECURITY NEWS"])
    security = [
        item for item in tech
        if any(word in item[0].lower() for word in security_words)
    ]

    # If fewer than 5 computer-security-specific stories are found,
    # fill the rest with general Fox Tech headlines.
    if len(security) < 5:
        for item in tech:
            if item not in security:
                security.append(item)
            if len(security) >= 5:
                break

    print_section("TOP 5 FOX NEWS WORLD HEADLINES", world)
    print_section("TOP 5 FOX NEWS U.S. HEADLINES", us)
    print_section("TOP 5 FOX NEWS COMPUTER SECURITY / TECH HEADLINES", security)

except Exception as e:
    print("Error pulling Fox News headlines:")
    print(e)
PY
echo
echo "================================================================================"
echo "End of Report"
echo "Press any key to close..."
echo "================================================================================"
read -n 1 -s
