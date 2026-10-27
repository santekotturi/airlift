"""Stream an Apple Health `export.zip` into Parquet.

The export is several GB of XML, so it is never unzipped or loaded whole:
`lxml.iterparse` walks it straight out of the zip and every element is freed
as soon as it is read.

Two outputs:

- `census.parquet` — every record type in the whole export, with count,
  sources and first/last date. Cheap, and it is how a new HealthKit type
  (or a gap in the history) shows up.
- `records.parquet` — every record inside the analysis window, all types,
  with metadata kept as JSON. Keeping all types, not a chosen few, is what
  lets `needle` search for a number Apple displays without knowing in
  advance which type stores it.
"""

from __future__ import annotations

import json
import zipfile
from collections import defaultdict
from datetime import datetime
from pathlib import Path

import pandas as pd
from lxml import etree

DATE_FORMAT = "%Y-%m-%d %H:%M:%S %z"


def parse_date(text: str | None) -> datetime | None:
    return datetime.strptime(text, DATE_FORMAT) if text else None


def _export_member(archive: zipfile.ZipFile) -> str:
    # `export_cda.xml` is the clinical-document copy; `export.xml` is the one
    # with every HealthKit record.
    for name in archive.namelist():
        if name.endswith("/export.xml") or name == "export.xml":
            return name
    raise FileNotFoundError("no export.xml inside the zip")


def ingest(zip_path: Path, out_dir: Path, since: str) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    since_dt = datetime.fromisoformat(since).astimezone()

    census: dict[str, dict] = defaultdict(
        lambda: {"count": 0, "first": None, "last": None, "sources": defaultdict(int)}
    )
    rows: list[dict] = []
    export_date = None

    with zipfile.ZipFile(zip_path) as archive, archive.open(_export_member(archive)) as stream:
        # The export carries an inline DTD; never resolve entities or fetch it.
        context = etree.iterparse(
            stream,
            events=("end",),
            tag=("Record", "ExportDate"),
            resolve_entities=False,
            no_network=True,
            load_dtd=False,
            huge_tree=True,
        )
        for _, element in context:
            if element.tag == "ExportDate":
                export_date = element.get("value")
            else:
                _read_record(element, census, rows, since_dt)
            element.clear()
            while element.getprevious() is not None:
                del element.getparent()[0]

    census_frame = pd.DataFrame(
        [
            {
                "type": record_type,
                "count": entry["count"],
                "first": entry["first"],
                "last": entry["last"],
                "sources": json.dumps(dict(entry["sources"]), ensure_ascii=False),
            }
            for record_type, entry in census.items()
        ]
    ).sort_values("type")
    census_frame.to_parquet(out_dir / "census.parquet", index=False)

    records = pd.DataFrame(rows)
    for column in ("start", "end", "created"):
        records[column] = pd.to_datetime(records[column], format=DATE_FORMAT, utc=True)
    records.to_parquet(out_dir / "records.parquet", index=False)

    (out_dir / "ingest.json").write_text(
        json.dumps(
            {
                "zip": str(zip_path),
                "export_date": export_date,
                "since": since,
                "records_in_window": len(records),
                "types": len(census_frame),
            },
            indent=2,
        )
    )
    print(f"export date {export_date}: {len(census_frame)} types, {len(records):,} records since {since}")


def _read_record(element, census, rows, since_dt) -> None:
    record_type = element.get("type", "").removeprefix("HKQuantityTypeIdentifier").removeprefix(
        "HKCategoryTypeIdentifier"
    )
    start = parse_date(element.get("startDate"))
    source = element.get("sourceName", "")

    entry = census[record_type]
    entry["count"] += 1
    entry["sources"][source] += 1
    if start is not None:
        if entry["first"] is None or start < entry["first"]:
            entry["first"] = start
        if entry["last"] is None or start > entry["last"]:
            entry["last"] = start

    if start is None or start < since_dt:
        return

    metadata = {child.get("key"): child.get("value") for child in element.iterfind("MetadataEntry")}
    beats = [
        (child.get("bpm"), child.get("time"))
        for child in element.iterfind("HeartRateVariabilityMetadataList/InstantaneousBeatsPerMinute")
    ]
    raw_value = element.get("value")
    try:
        value = float(raw_value) if raw_value is not None else None
    except ValueError:
        value = None  # category values like HKCategoryValueSleepAnalysisAsleepDeep

    rows.append(
        {
            "type": record_type,
            "source": source,
            "source_version": element.get("sourceVersion"),
            "device": element.get("device"),
            "unit": element.get("unit"),
            "start": element.get("startDate"),
            "end": element.get("endDate"),
            "created": element.get("creationDate"),
            "value": value,
            "category": None if value is not None else raw_value,
            "metadata": json.dumps(metadata, ensure_ascii=False) if metadata else None,
            "beats": json.dumps(beats) if beats else None,
        }
    )
