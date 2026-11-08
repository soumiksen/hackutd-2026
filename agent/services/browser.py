"""One place to start Chromium, so the container setting applies to every flow."""
import os


async def launch(pw):
    """Headless Chromium. Inside Docker the browser runs as root, where Chromium refuses to start with its sandbox;
    the container is the isolation, so CHROMIUM_NO_SANDBOX=1 (set by the deploy image) turns the sandbox off."""
    args = ["--no-sandbox"] if os.environ.get("CHROMIUM_NO_SANDBOX") == "1" else []
    return await pw.chromium.launch(headless=True, args=args)
