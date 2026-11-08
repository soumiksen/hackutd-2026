"""Sign up, sign in, sessions. Passwords are hashed with scrypt here; the store only sees the hash."""
import base64
import hashlib
import hmac
import re
import secrets
import time
from datetime import datetime, timedelta, timezone

from . import errors
from .store import get_store

SESSION_DAYS = 30
EMAIL_RE = re.compile(r"^[^@\s]{1,64}@[^@\s]{1,255}\.[^@\s]{2,}$")
N, R, P = 2 ** 14, 8, 1
USER_ID_RE = re.compile(r"^[A-Za-z0-9_\-]{1,64}$")


def normalize_email(email: str) -> str:
    e = (email or "").strip().lower()
    if not EMAIL_RE.match(e) or any(ord(c) < 32 for c in e):
        raise errors.validation("Enter a valid email address.")
    return e


def check_password(pw: str):
    if not (8 <= len(pw or "") <= 128):
        raise errors.validation("Password must be 8 to 128 characters.")


def hash_password(pw: str) -> str:
    salt = secrets.token_bytes(16)
    h = hashlib.scrypt(pw.encode(), salt=salt, n=N, r=R, p=P, dklen=32, maxmem=64 * 1024 * 1024)
    return f"scrypt${N}${R}${P}${base64.b64encode(salt).decode()}${base64.b64encode(h).decode()}"


def verify_password(pw: str, stored: str) -> bool:
    try:
        _, n, r, p, salt, h = stored.split("$")
        calc = hashlib.scrypt(pw.encode(), salt=base64.b64decode(salt), n=int(n), r=int(r), p=int(p),
                              dklen=32, maxmem=64 * 1024 * 1024)
        return hmac.compare_digest(calc, base64.b64decode(h))
    except Exception:
        return False


_DUMMY = hash_password("not-a-real-password")  # compared against when the email is unknown, so timing does not leak it


def token_hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def new_session(user_id: str) -> tuple[str, str]:
    token = secrets.token_urlsafe(32)
    exp = (datetime.now(timezone.utc) + timedelta(days=SESSION_DAYS)).strftime("%Y-%m-%dT%H:%M:%SZ")
    get_store().create_session(token_hash(token), user_id, exp)
    return token, exp


def resolve(token: str) -> str:
    """Session token -> user_id, or 401."""
    s = get_store().get_session(token_hash(token.strip())) if token and len(token) < 200 else None
    if not s or s["expires_at"] < datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"):
        raise errors.unauthorized("Your session has expired. Sign in again.")
    return s["user_id"]


# ---- sign-in throttle: 5 failures per 10 minutes per email (in memory) ----
_fails: dict[str, list[float]] = {}
WINDOW, MAX_FAILS = 600, 5


def _recent(key: str) -> list[float]:
    now = time.time()
    _fails[key] = [t for t in _fails.get(key, []) if now - t < WINDOW]
    return _fails[key]


def authenticate(email: str, password: str) -> str:
    email = normalize_email(email)
    if len(_recent(email)) >= MAX_FAILS:
        raise errors.ApiError(429, "rate_limited", "Too many sign-in attempts. Try again in a few minutes.")
    cred = get_store().get_credential(email=email)
    ok = verify_password(password or "", cred["password_hash"] if cred else _DUMMY)
    if not (cred and ok):
        _fails[email].append(time.time())
        raise errors.unauthorized("Wrong email or password.")
    _fails.pop(email, None)
    return cred["user_id"]


def reset_throttle():
    _fails.clear()
