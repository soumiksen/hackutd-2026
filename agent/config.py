"""Env vars. Names come from API_CONTRACT.md section 1."""
import os
from pathlib import Path

from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parent.parent
load_dotenv(ROOT / ".env")


def _get(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


class Settings:
    """Read lazily so tests can monkeypatch the environment."""

    @property
    def public_base_url(self): return _get("PUBLIC_BASE_URL", "http://localhost:8000").rstrip("/")
    @property
    def database_url(self): return _get("DATABASE_URL", "sqlite:///./parkour.db")
    @property
    def nvidia_api_key(self): return _get("NVIDIA_API_KEY")
    @property
    def nvidia_base_url(self): return _get("NVIDIA_BASE_URL", "https://integrate.api.nvidia.com/v1")
    @property
    def nemotron_model(self): return _get("NEMOTRON_MODEL", "nvidia/nemotron-3-super-120b-a12b")
    @property
    def vision_model(self): return _get("VISION_MODEL")
    @property
    def photon_webhook_secret(self): return _get("PHOTON_WEBHOOK_SECRET")
    @property
    def messenger_url(self): return _get("MESSENGER_URL", "http://localhost:8790").rstrip("/")
    @property
    def internal_api_key(self): return _get("INTERNAL_API_KEY")
    @property
    def mock_portal_url(self): return _get("MOCK_PORTAL_URL", "http://localhost:8001").rstrip("/")
    @property
    def demo_mode(self): return _get("DEMO_MODE", "false").lower() == "true"
    @property
    def demo_portal_params(self): return _get("DEMO_PORTAL_PARAMS")

    @property
    def db_path(self) -> str:
        url = self.database_url
        path = url.split("sqlite:///", 1)[1] if url.startswith("sqlite:///") else url
        p = Path(path)
        return str(p if p.is_absolute() else ROOT / p)

    @property
    def data_dir(self) -> Path:
        return Path(_get("DATA_DIR", str(ROOT / "data")))

    @property
    def proofs_dir(self) -> Path:
        return Path(_get("PROOFS_DIR", str(ROOT / "proofs")))


settings = Settings()
