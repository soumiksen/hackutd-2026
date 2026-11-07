"""Nemotron through NVIDIA's OpenAI-compatible API. JSON only, schema-validated, cached."""
import asyncio
import hashlib
import json
import logging
import re
from typing import TypeVar

from pydantic import BaseModel, ValidationError

from .. import db, errors
from ..config import settings

log = logging.getLogger("parkour.llm")
T = TypeVar("T", bound=BaseModel)

_client = None


def client():
    global _client
    if _client is None:
        from openai import AsyncOpenAI
        _client = AsyncOpenAI(base_url=settings.nvidia_base_url, api_key=settings.nvidia_api_key or "missing")
    return _client


def extract_json(text: str) -> dict:
    """Strip reasoning blocks and return the first balanced JSON object."""
    text = re.sub(r"<think>.*?</think>", "", text or "", flags=re.S)
    text = re.sub(r"^.*?</think>", "", text, flags=re.S)  # unterminated opener
    start = text.find("{")
    if start < 0:
        raise ValueError("no JSON object")
    depth, in_str, esc = 0, False, False
    for i in range(start, len(text)):
        ch = text[i]
        if in_str:
            if esc: esc = False
            elif ch == "\\": esc = True
            elif ch == '"': in_str = False
        elif ch == '"': in_str = True
        elif ch == "{": depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return json.loads(text[start:i + 1])
    raise ValueError("unbalanced JSON")


def cache_key(task: str, payload: str) -> str:
    return hashlib.sha256(f"{task}\n{payload}".encode()).hexdigest()


def _cache_get(key: str) -> dict | None:
    rows = db.query("SELECT value FROM llm_cache WHERE key=?", (key,))
    return json.loads(rows[0]["value"]) if rows else None


def _cache_put(key: str, value: dict):
    db.execute("INSERT OR REPLACE INTO llm_cache (key, value) VALUES (?,?)", (key, json.dumps(value)))


async def _complete(model: str, messages: list[dict]) -> str:
    resp = await asyncio.wait_for(client().chat.completions.create(
        model=model, messages=messages, temperature=0, max_tokens=1024), timeout=45)
    return resp.choices[0].message.content or ""


async def chat_json(task: str, system: str, user: str, schema: type[T], *,
                    model: str | None = None, images: list[str] | None = None) -> T:
    """Call the model, parse the first JSON object, validate, retry once, else llm_unavailable.

    `images` are data URLs; when given the message uses the OpenAI image_url format.
    Results are cached by input hash. DEMO_MODE returns the cache first.
    """
    model = model or settings.nemotron_model
    key = cache_key(task, f"{model}\n{system}\n{user}\n{[hashlib.sha256(i.encode()).hexdigest() for i in images or []]}")
    if settings.demo_mode and (hit := _cache_get(key)) is not None:
        try:
            return schema.model_validate(hit)
        except ValidationError:
            pass
    if not settings.nvidia_api_key:
        if (hit := _cache_get(key)) is not None:
            return schema.model_validate(hit)
        raise errors.llm_unavailable("NVIDIA_API_KEY is not configured.")

    content: str | list = user
    if images:
        content = [{"type": "text", "text": user}] + [
            {"type": "image_url", "image_url": {"url": u}} for u in images]
    msgs = [{"role": "system", "content": system + "\nRespond with one JSON object only. No prose."},
            {"role": "user", "content": content}]
    last: Exception | None = None
    for attempt in range(2):
        try:
            raw = await _complete(model, msgs)
            obj = schema.model_validate(extract_json(raw))
            _cache_put(key, obj.model_dump())
            return obj
        except (ValueError, ValidationError) as e:  # bad output: retry once
            last = e
            msgs.append({"role": "user", "content": "That was not valid. Return only the JSON object."})
        except Exception as e:  # network, rate limit, timeout
            last = e
            await asyncio.sleep(1.5)
    log.warning("llm task=%s failed: %s", task, type(last).__name__)
    if (hit := _cache_get(key)) is not None:
        return schema.model_validate(hit)
    raise errors.llm_unavailable()


async def chat_text(task: str, system: str, user: str) -> str:
    if not settings.nvidia_api_key:
        raise errors.llm_unavailable("NVIDIA_API_KEY is not configured.")
    try:
        raw = await _complete(settings.nemotron_model,
                              [{"role": "system", "content": system}, {"role": "user", "content": user}])
    except Exception:
        raise errors.llm_unavailable()
    return re.sub(r"<think>.*?</think>", "", raw, flags=re.S).strip()
