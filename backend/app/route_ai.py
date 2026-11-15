"""Ask Gemini which walking route is safer at night, with a short reason.

Input: candidate routes with their turn-by-turn street instructions (from Apple Maps on the
phone). Output: the safer route id plus a one-line reason per route. Gemini has no live crime
or lighting data, so this is an informed guess; on any failure we fall back to a street-based
rule (main named streets and campus malls good, paths/alleys/parking lots bad, fewer turns good).
"""
import json
import logging
import os
import re

import httpx

log = logging.getLogger("pupdate.route_ai")
BASE = "https://generativelanguage.googleapis.com/v1beta"
MAIN = re.compile(r"\b(Dr|Ave|Blvd|St|Rd|Pkwy|Way|Mall|Street|Avenue|Drive|Road|Boulevard)\b", re.I)
RISKY = re.compile(r"\b(path|trail|alley|parking|lot|walkway|footpath|service|underpass|tunnel)\b", re.I)


def flag_hits(routes, flags):
    from .flags import brief, on_path
    return {r["id"]: [brief(f) for f in on_path(r.get("points") or [], flags)] for r in routes}


def _avoid_count(hits, rid):
    return sum(1 for f in hits.get(rid, []) if f["status"] == "avoid")


def heuristic(routes, hits=None):
    hits = hits or {}

    def score(r):
        steps = r.get("steps") or []
        main = sum(1 for s in steps if MAIN.search(s))
        risky = sum(1 for s in steps if RISKY.search(s))
        n = max(1, len(steps))
        caution = sum(1 for f in hits.get(r["id"], []) if f["status"] == "caution")
        return main / n - risky / n - 0.03 * max(0, n - 2) - 1.0 * _avoid_count(hits, r["id"]) - 0.25 * caution
    best = max(routes, key=score)
    reasons = {}
    for r in routes:
        steps = r.get("steps") or []
        risky = [s for s in steps if RISKY.search(s)]
        fl = hits.get(r["id"], [])
        avoid = [f for f in fl if f["status"] == "avoid"]
        if avoid:
            f = avoid[0]
            reasons[r["id"]] = f"Passes a spot {f['by_name']} flagged to avoid: {f['reason'].lower()}."
        elif fl:
            f = fl[0]
            reasons[r["id"]] = f"Passes {f['by_name']}'s caution flag: {f['reason'].lower()}."
        elif risky:
            reasons[r["id"]] = "Includes a path or lot that may be poorly lit."
        elif any(hits.values()):
            reasons[r["id"]] = "Avoids the areas your circle flagged."
        else:
            reasons[r["id"]] = "Sticks to named streets."
    return {"safer_id": best["id"], "reasons": reasons, "source": "rule"}


def _gemini(routes, hour, hits=None):
    key = os.getenv("GEMINI_API_KEY")
    if not key:
        return None
    model = os.getenv("GEMINI_MODEL") or "gemini-3.5-flash-lite"
    lines = []
    for r in routes:
        steps = "; ".join((r.get("steps") or [])[:25])
        fl = (hits or {}).get(r["id"], [])
        flag_txt = "; ".join(f"{f['status'].upper()} flag by {f['by_name']}: {f['reason']}"
                             + (f" ({f['note']})" if f.get("note") else "") for f in fl) or "none"
        lines.append(f'- id "{r["id"]}": {round(r.get("distance_m", 0))} m, {round(r.get("minutes", 0))} min. '
                     f'Steps: {steps}. Friends\' flags on this route: {flag_txt}')
    prompt = (
        "You help a student pick the safer of several walking routes home at night "
        f"(local hour {hour}). Judge only from the street names and steps: prefer busy, main, "
        "well-lit named streets and open campus malls; avoid alleys, unlit paths, parking lots, "
        "underpasses and long detours through empty areas. You have no live crime data, so do not "
        "claim any. Friends in the walker's circle flag spots: never pick a route with an AVOID flag when another "
        "route has none, count CAUTION flags against a route, and mention a flag (who flagged it and why) in that "
        "route's reason. Reply as JSON only: {\"safer_id\": str, \"reasons\": {\"<id>\": \"one short sentence, "
        "under 90 characters, mentioning a street by name, never the route id\"}}.\nRoutes:\n" + "\n".join(lines)
    )
    body = {"contents": [{"role": "user", "parts": [{"text": prompt}]}],
            "generationConfig": {"responseMimeType": "application/json", "temperature": 0.2}}
    r = httpx.post(f"{BASE}/models/{model}:generateContent", headers={"x-goog-api-key": key}, json=body, timeout=8)
    r.raise_for_status()
    parts = r.json()["candidates"][0]["content"]["parts"]
    text = next(p["text"] for p in parts if p.get("text") and not p.get("thought"))
    data = json.loads(text[text.find("{"): text.rfind("}") + 1])
    ids = {x["id"] for x in routes}
    if data.get("safer_id") not in ids:
        return None
    reasons = {k: str(v)[:120] for k, v in (data.get("reasons") or {}).items() if k in ids}
    return {"safer_id": data["safer_id"], "reasons": reasons, "source": "gemini"}


def assess(routes, hour=21, flags=None):
    if not routes:
        return {"safer_id": None, "reasons": {}, "source": "none", "flags": {}}
    hits = flag_hits(routes, flags or [])
    rule = heuristic(routes, hits)
    out = None
    try:
        out = _gemini(routes, hour, hits)
    except Exception as e:
        log.warning("gemini route assess failed: %s", e)
    if out:
        for r in routes:  # fill any reason Gemini skipped
            out["reasons"].setdefault(r["id"], rule["reasons"][r["id"]])
        # Hard rule on top of Gemini: never recommend an Avoid flag when a clean route exists.
        if _avoid_count(hits, out["safer_id"]) and any(_avoid_count(hits, r["id"]) == 0 for r in routes):
            out["safer_id"] = rule["safer_id"]
        log.info("route assess via gemini: %s", out["safer_id"])
    else:
        out = rule
    out["flags"] = hits
    return out
