"""SQLite via plain sqlite3. Documents are JSON blobs with indexed columns."""
import json
import sqlite3
import threading
from contextlib import contextmanager

from .config import settings

_lock = threading.RLock()
_conn: sqlite3.Connection | None = None
_conn_path: str | None = None

SCHEMA = """
CREATE TABLE IF NOT EXISTS users (user_id TEXT PRIMARY KEY, data TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS vehicles (vehicle_id TEXT PRIMARY KEY, user_id TEXT NOT NULL, data TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS properties (property_id TEXT PRIMARY KEY, data TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS registrations (
  registration_id TEXT PRIMARY KEY, user_id TEXT NOT NULL, status TEXT NOT NULL,
  created_at TEXT NOT NULL, data TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS proof_files (
  registration_id TEXT NOT NULL, filename TEXT NOT NULL, captured_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS plans (plan_id TEXT PRIMARY KEY, user_id TEXT NOT NULL, data TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS receipts (receipt_id TEXT PRIMARY KEY, plan_id TEXT NOT NULL, data TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS llm_cache (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS message_log (at TEXT NOT NULL, event TEXT NOT NULL, ok INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS webhook_seen (message_id TEXT PRIMARY KEY);
"""


def conn() -> sqlite3.Connection:
    global _conn, _conn_path
    path = settings.db_path
    if _conn is None or _conn_path != path:
        _conn = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        _conn.row_factory = sqlite3.Row
        _conn.executescript(SCHEMA)
        _conn_path = path
    return _conn


def reset():
    """Close the cached connection (tests)."""
    global _conn, _conn_path
    if _conn:
        _conn.close()
    _conn = _conn_path = None


@contextmanager
def tx():
    with _lock:
        yield conn()


def put(table: str, key_col: str, key: str, doc: dict, **cols):
    names = [key_col, *cols, "data"]
    vals = [key, *cols.values(), json.dumps(doc)]
    with tx() as c:
        c.execute(
            f"INSERT OR REPLACE INTO {table} ({','.join(names)}) VALUES ({','.join('?' * len(names))})", vals)


def get(table: str, key_col: str, key: str) -> dict | None:
    with tx() as c:
        row = c.execute(f"SELECT data FROM {table} WHERE {key_col}=?", (key,)).fetchone()
    return json.loads(row["data"]) if row else None


def query(sql: str, args: tuple = ()) -> list[sqlite3.Row]:
    with tx() as c:
        return c.execute(sql, args).fetchall()


def execute(sql: str, args: tuple = ()):
    with tx() as c:
        c.execute(sql, args)
