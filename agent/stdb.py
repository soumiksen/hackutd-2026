"""Tiny SpacetimeDB HTTP client (docs: /v1/database/:name/call/:reducer and /sql).

The API connects as the database owner, so reducers accept it and private tables are readable by SQL.
"""
import re

import httpx

SAFE_ID = re.compile(r"^[A-Za-z0-9_\-:.]{1,128}$")


class StdbError(Exception):
    def __init__(self, status: int, body: str):
        self.status, self.body = status, body
        super().__init__(f"SpacetimeDB {status}: {body[:200]}")


def quote(value: str) -> str:
    """SQL string literal. Single quotes are doubled; control characters are refused."""
    if any(ord(c) < 32 for c in value):
        raise ValueError("control characters are not allowed in query values")
    return "'" + value.replace("'", "''") + "'"


def ident(value: str) -> str:
    """For ids that the API generated or validated: refuse anything unusual instead of escaping it."""
    if not SAFE_ID.match(value or ""):
        raise ValueError("unsafe identifier")
    return quote(value)


def _unwrap(v):
    """Sum values come as {"<tag>": value}; Option is not used by this module, but unwrap defensively."""
    if isinstance(v, dict) and len(v) == 1:
        k, inner = next(iter(v.items()))
        if k in ("0", "some"):
            return inner
        if k in ("1", "none"):
            return None
    return v


class Stdb:
    def __init__(self, uri: str, database: str, token: str, timeout: float = 5.0, transport=None):
        self.database = database
        self.http = httpx.Client(base_url=uri, timeout=timeout, transport=transport,
                                 headers={"Authorization": f"Bearer {token}"} if token else {})

    def call(self, reducer: str, args: list) -> None:
        r = self.http.post(f"/v1/database/{self.database}/call/{reducer}", json=args)
        if r.status_code >= 400:
            raise StdbError(r.status_code, r.text)

    def sql(self, query: str) -> list[dict]:
        r = self.http.post(f"/v1/database/{self.database}/sql", content=query, headers={"Content-Type": "text/plain"})
        if r.status_code >= 400:
            raise StdbError(r.status_code, r.text)
        out: list[dict] = []
        for stmt in r.json():
            names = [(e.get("name") or {}).get("some") if isinstance(e.get("name"), dict) else e.get("name")
                     for e in stmt["schema"]["elements"]]
            for row in stmt["rows"]:
                out.append({n: _unwrap(v) for n, v in zip(names, row)} if isinstance(row, list)
                           else {k: _unwrap(v) for k, v in row.items()})
        return out

    def ping(self) -> bool:
        try:
            return self.http.get("/v1/ping").status_code < 400
        except httpx.HTTPError:
            return False
