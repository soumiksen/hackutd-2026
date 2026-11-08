"""Domain allowlist and URL checks (backend-plan section 6 step 3, section 8)."""
import re
from urllib.parse import urlparse

from . import errors
from .services import data as seed

URL_RE = re.compile(r"https?://[^\s<>\"']+", re.I)


def host_of(url: str) -> str | None:
    try:
        return (urlparse(url).hostname or "").lower() or None
    except ValueError:
        return None


def is_allowed(url: str, extra_hosts: set[str] | frozenset = frozenset()) -> bool:
    host = host_of(url)
    if not host:
        return False
    if url.rstrip("/") in {u.rstrip("/") for u in seed.blocked_urls()}:
        return False
    return host in {d.lower() for d in seed.allowed_domains()} | {h.lower() for h in extra_hosts}


def check_url(url: str, extra_hosts: set[str] | frozenset = frozenset()) -> None:
    if not is_allowed(url, extra_hosts):
        raise errors.unknown_domain(f"Blocked: {host_of(url) or 'invalid URL'} is not an approved portal domain.")


def check_text_urls(text: str) -> None:
    """Run the same check on any URL found in a QR payload or message."""
    for u in URL_RE.findall(text or ""):
        check_url(u)
