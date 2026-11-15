"""State persistence.

Three modes, picked from the environment:
- MONGODB_URI set (Vultr server): state stays in memory with the background loop, and a JSON
  snapshot is saved to MongoDB after every change and loaded at startup.

Local (no Redis env vars): state lives in memory and a background loop advances demo walks.
Cloud (Upstash Redis via Vercel): every request takes a short Redis lock, loads the whole
state, catches the demo simulator up to "now", runs, saves, and unlocks. Serverless functions
can then run on any instance and the state stays consistent.
"""
import json
import logging
import os
import time
import uuid

import httpx

log = logging.getLogger("pupdate.store")
KEY = "wb:state"
LOCK = "wb:lock"


def _cfg():
    url = os.getenv("KV_REST_API_URL") or os.getenv("UPSTASH_REDIS_REST_URL")
    token = os.getenv("KV_REST_API_TOKEN") or os.getenv("UPSTASH_REDIS_REST_TOKEN")
    return (url.rstrip("/"), token) if url and token else (None, None)


def enabled():
    return _cfg()[0] is not None


_client = None


def _cmd(*args):
    global _client
    url, token = _cfg()
    if _client is None:
        _client = httpx.Client(timeout=5.0)
    r = _client.post(url, headers={"Authorization": f"Bearer {token}"}, json=list(args))
    r.raise_for_status()
    return r.json().get("result")


def acquire(timeout=4.0):
    """Spin on SET NX PX. Returns a token to release with, or None if it could not lock."""
    token = uuid.uuid4().hex
    end = time.time() + timeout
    while time.time() < end:
        if _cmd("SET", LOCK, token, "NX", "PX", "4000") == "OK":
            return token
        time.sleep(0.03)
    log.warning("state lock timeout; proceeding without lock")
    return None


def release(token):
    if token is None:
        return
    # Only delete the lock if we still own it.
    script = "if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) else return 0 end"
    try:
        _cmd("EVAL", script, "1", LOCK, token)
    except Exception as e:
        log.warning("lock release failed: %s", e)


def load():
    raw = _cmd("GET", KEY)
    return json.loads(raw) if raw else None


def save(data):
    _cmd("SET", KEY, json.dumps(data, separators=(",", ":")))


# ---------------------------------------------------------------------------
# MongoDB snapshot mode (single always-on server, e.g. Vultr).
# ---------------------------------------------------------------------------

_mongo = None


def mongo_enabled():
    return bool(os.getenv("MONGODB_URI"))


def _coll():
    global _mongo
    if _mongo is None:
        from pymongo import MongoClient
        _mongo = MongoClient(os.getenv("MONGODB_URI"), serverSelectionTimeoutMS=5000)
    return _mongo[os.getenv("MONGODB_DB", "walkbuddy")]["state"]


def mongo_load():
    try:
        doc = _coll().find_one({"_id": "state"})
        return json.loads(doc["json"]) if doc else None
    except Exception as e:
        log.warning("mongo load failed: %s", e)
        return None


def mongo_save(data):
    try:
        _coll().replace_one({"_id": "state"}, {"_id": "state", "json": json.dumps(data, separators=(",", ":")),
                                               "saved_at": time.time()}, upsert=True)
    except Exception as e:
        log.warning("mongo save failed: %s", e)
