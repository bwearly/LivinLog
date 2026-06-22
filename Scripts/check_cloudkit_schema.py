#!/usr/bin/env python3
"""
check_cloudkit_schema.py — CloudKit Production schema checklist diff

Parses the live Core Data model and the "CloudKit Production schema
checklist" table in ReliabilityArchitectureReport.md, then diffs them.

Usage (from repo root):
    python3 Scripts/check_cloudkit_schema.py

Exit codes:
    0  No dangerous gaps: every model attribute/relationship is in the checklist.
    1  Dangerous gaps found: model item(s) missing from the checklist table.
       Fix the table (or deploy the schema to Production) before the next TestFlight build.
"""

import os
import sys
import xml.etree.ElementTree as ET

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

MODEL_PATH = os.path.join(
    REPO_ROOT,
    "Livin Log",
    "LivinLog.xcdatamodeld",
    "LivinLog.xcdatamodel",
    "contents",
)

REPORT_PATH = os.path.join(REPO_ROOT, "ReliabilityArchitectureReport.md")

CHECKLIST_HEADING = "## CloudKit Production schema checklist"


# ---------------------------------------------------------------------------
# Parsers
# ---------------------------------------------------------------------------

def parse_model(path: str) -> dict:
    """Return {entity_name: {"attributes": set, "relationships": set}}."""
    try:
        tree = ET.parse(path)
    except FileNotFoundError:
        sys.exit(f"ERROR: Core Data model not found at {path}")
    except ET.ParseError as e:
        sys.exit(f"ERROR: Could not parse Core Data model XML: {e}")

    root = tree.getroot()
    entities = {}
    for entity in root.findall("entity"):
        name = entity.get("name")
        if not name:
            continue
        attrs = {
            a.get("name")
            for a in entity.findall("attribute")
            if a.get("name")
        }
        rels = {
            r.get("name")
            for r in entity.findall("relationship")
            if r.get("name")
        }
        entities[name] = {"attributes": attrs, "relationships": rels}
    return entities


def _parse_cell(cell: str) -> set:
    """Split a comma-separated, backtick-wrapped cell into a set of names."""
    result = set()
    for item in cell.split(","):
        name = item.strip().strip("`").strip()
        if name:
            result.add(name)
    return result


def parse_checklist(path: str) -> dict:
    """
    Return {entity_name: {"attributes": set, "relationships": set}} by
    parsing the first Markdown table found under CHECKLIST_HEADING.
    """
    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except FileNotFoundError:
        sys.exit(f"ERROR: Report not found at {path}")

    # Locate the section heading
    section_start = None
    for i, line in enumerate(lines):
        if line.strip() == CHECKLIST_HEADING:
            section_start = i
            break

    if section_start is None:
        sys.exit(f"ERROR: Could not find '{CHECKLIST_HEADING}' in {path}")

    entities = {}
    in_table = False

    for line in lines[section_start:]:
        stripped = line.rstrip()

        if not stripped.startswith("|"):
            if in_table:
                break   # first non-pipe line after table rows → table is done
            continue

        in_table = True

        # Skip separator row (| --- | --- | ... |)
        if "---" in stripped:
            continue

        parts = [p.strip() for p in stripped.split("|")]
        # parts: ['', entity, attributes, relationships, '']
        if len(parts) < 4:
            continue

        entity_raw = parts[1]

        # Skip the header row
        if entity_raw.lower() == "entity":
            continue

        entity_name = entity_raw.strip("`").strip()
        if not entity_name:
            continue

        entities[entity_name] = {
            "attributes":    _parse_cell(parts[2]),
            "relationships": _parse_cell(parts[3]),
        }

    return entities


# ---------------------------------------------------------------------------
# Diff and report
# ---------------------------------------------------------------------------

def main():
    model     = parse_model(MODEL_PATH)
    checklist = parse_checklist(REPORT_PATH)

    unchecked_entities = []   # entity in model, no checklist row at all
    dangerous_gaps     = []   # (entity, missing_attrs, missing_rels)  — model→checklist
    stale_items        = []   # (entity, stale_attrs, stale_rels)      — checklist→model

    for entity_name, model_data in sorted(model.items()):
        if entity_name not in checklist:
            unchecked_entities.append(entity_name)
            continue

        checklist_data = checklist[entity_name]

        missing_attrs = model_data["attributes"]    - checklist_data["attributes"]
        missing_rels  = model_data["relationships"] - checklist_data["relationships"]
        if missing_attrs or missing_rels:
            dangerous_gaps.append(
                (entity_name, sorted(missing_attrs), sorted(missing_rels))
            )

        stale_attrs = checklist_data["attributes"]    - model_data["attributes"]
        stale_rels  = checklist_data["relationships"] - model_data["relationships"]
        if stale_attrs or stale_rels:
            stale_items.append(
                (entity_name, sorted(stale_attrs), sorted(stale_rels))
            )

    # Entities that appear clean (in both, no diffs)
    gap_entities   = {e for e, _, _ in dangerous_gaps}
    stale_entities = {e for e, _, _ in stale_items}
    clean_entities = sorted(
        e for e in model if e in checklist
        and e not in gap_entities and e not in stale_entities
    )

    # -----------------------------------------------------------------------
    # Print report
    # -----------------------------------------------------------------------
    WIDTH = 70
    print("=" * WIDTH)
    print("CloudKit Production Schema Checklist Diff")
    print("=" * WIDTH)
    print()

    if unchecked_entities:
        print("⛔  ENTITIES IN MODEL WITH NO CHECKLIST ROW  (highest risk — all fields unchecked)")
        for name in sorted(unchecked_entities):
            print(f"    - {name}")
        print()

    if dangerous_gaps:
        print("❌  MODEL ITEMS MISSING FROM CHECKLIST  (dangerous — may cause sync failures in TestFlight/Production)")
        for entity_name, attrs, rels in dangerous_gaps:
            if attrs:
                print(f"    {entity_name}  attributes missing from checklist: {', '.join(attrs)}")
            if rels:
                print(f"    {entity_name}  relationships missing from checklist: {', '.join(rels)}")
        print()

    if stale_items:
        print("⚠️   CHECKLIST ITEMS NOT IN LIVE MODEL  (stale documentation — lower risk)")
        for entity_name, attrs, rels in stale_items:
            if attrs:
                print(f"    {entity_name}  stale attributes: {', '.join(attrs)}")
            if rels:
                print(f"    {entity_name}  stale relationships: {', '.join(rels)}")
        print()

    if clean_entities:
        print("✅  CLEAN  (model and checklist match)")
        for name in clean_entities:
            print(f"    - {name}")
        print()

    # -----------------------------------------------------------------------
    # Summary and exit code
    # -----------------------------------------------------------------------
    print("-" * WIDTH)

    if not dangerous_gaps and not unchecked_entities:
        print("RESULT: No dangerous gaps. Checklist is in sync with the live model.")
        sys.exit(0)
    else:
        total_dangerous = len(unchecked_entities) + sum(
            len(a) + len(r) for _, a, r in dangerous_gaps
        )
        print(
            f"RESULT: {total_dangerous} dangerous item(s) found. "
            "Update the checklist table in ReliabilityArchitectureReport.md "
            "and confirm deployment to CloudKit Production before the next TestFlight build."
        )
        sys.exit(1)


if __name__ == "__main__":
    main()
