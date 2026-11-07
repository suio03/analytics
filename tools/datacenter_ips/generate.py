#!/usr/bin/env python3
"""Regenerate priv/datacenter_ips/ranges.txt from public cloud provider IP lists.

Usage: python3 -I tools/datacenter_ips/generate.py

The output holds one collapsed CIDR per line. Plausible.Ingestion.DatacenterIP
loads it at boot. Cloudflare is left out on purpose: its ranges carry privacy
relays (WARP, iCloud Private Relay) used by real people.
"""
import csv
import io
import ipaddress
import json
import pathlib
import urllib.request

SOURCES = {
    "aws": "https://ip-ranges.amazonaws.com/ip-ranges.json",
    "gcp": "https://www.gstatic.com/ipranges/cloud.json",
    "oracle": "https://docs.oracle.com/en-us/iaas/tools/public_ip_ranges.json",
    "digitalocean": "https://digitalocean.com/geo/google.csv",
    "linode": "https://geoip.linode.com/",
}

OUT = pathlib.Path(__file__).resolve().parents[2] / "priv" / "datacenter_ips" / "ranges.txt"


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "recount-datacenter-ips/1.0"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return resp.read().decode("utf-8")


def aws(text):
    data = json.loads(text)
    yield from (p["ip_prefix"] for p in data["prefixes"])
    yield from (p["ipv6_prefix"] for p in data["ipv6_prefixes"])


def gcp(text):
    for p in json.loads(text)["prefixes"]:
        yield p.get("ipv4Prefix") or p.get("ipv6Prefix")


def oracle(text):
    for region in json.loads(text)["regions"]:
        for c in region["cidrs"]:
            yield c["cidr"]


def csv_first_column(text):
    for row in csv.reader(io.StringIO(text)):
        if row and not row[0].startswith("#"):
            yield row[0].strip()


PARSERS = {"aws": aws, "gcp": gcp, "oracle": oracle, "digitalocean": csv_first_column, "linode": csv_first_column}


def main():
    nets = []
    for name, url in SOURCES.items():
        count = 0
        for cidr in PARSERS[name](fetch(url)):
            try:
                nets.append(ipaddress.ip_network(cidr, strict=False))
                count += 1
            except ValueError:
                pass
        print(f"{name}: {count} prefixes")

    v4 = ipaddress.collapse_addresses(n for n in nets if n.version == 4)
    v6 = ipaddress.collapse_addresses(n for n in nets if n.version == 6)
    lines = [str(n) for n in list(v4) + list(v6)]
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n".join(lines) + "\n")
    print(f"wrote {len(lines)} ranges to {OUT}")


if __name__ == "__main__":
    main()
