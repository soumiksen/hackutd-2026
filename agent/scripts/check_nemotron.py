"""B0 check: one Nemotron text call works, list models, pick VISION_MODEL.

Run from the repo root: .venv/bin/python -m agent.scripts.check_nemotron
"""
import asyncio

from openai import AsyncOpenAI

from agent.config import settings

HINTS = ("vl", "vision", "nemotron", "llama-3.2", "phi-3.5-vision", "neva", "vila")


async def main():
    if not settings.nvidia_api_key:
        raise SystemExit("Set NVIDIA_API_KEY in .env (key from build.nvidia.com).")
    c = AsyncOpenAI(base_url=settings.nvidia_base_url, api_key=settings.nvidia_api_key)
    r = await c.chat.completions.create(model=settings.nemotron_model, max_tokens=64, temperature=0,
                                        messages=[{"role": "user", "content": 'Reply with the JSON {"ok": true}.'}])
    print("Nemotron reply:", (r.choices[0].message.content or "").strip()[:200])
    models = [m.id for m in (await c.models.list()).data]
    cands = [m for m in models if any(h in m.lower() for h in ("vl", "vision", "neva", "vila")) ]
    print("Vision-looking models (check each model card for the image format and free access):")
    for m in cands or ["(none matched; read the build.nvidia.com catalog)"]:
        print("  ", m)
    print("VISION_MODEL currently:", settings.vision_model or "(unset)")

asyncio.run(main())
