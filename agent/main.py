"""Parkour API (FastAPI). Endpoint paths and shapes follow API_CONTRACT.md section 5."""
import asyncio
import json
import logging
import uuid
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, File, Form, Header, Request, UploadFile
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles

from . import db, errors
from .config import settings
from .models import (AnswerIn, CheckoutIn, ConfirmIn, DraftIn, PatchIn, RenewIn, UserIn, VehicleIn)
from .services import drafts, messaging, properties, reminders, signs, vision

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(message)s")


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings.proofs_dir.mkdir(parents=True, exist_ok=True)
    db.conn()
    properties.load_into_db()
    task = asyncio.create_task(reminders.loop())
    yield
    task.cancel()


app = FastAPI(title="Parkour API", lifespan=lifespan)
settings.proofs_dir.mkdir(parents=True, exist_ok=True)
app.mount("/proofs", StaticFiles(directory=str(settings.proofs_dir)), name="proofs")  # endpoint 21


@app.exception_handler(errors.ApiError)
async def api_error(_: Request, e: errors.ApiError):
    return JSONResponse(e.body(), status_code=e.status)


@app.exception_handler(RequestValidationError)
async def bad_request(_: Request, e: RequestValidationError):
    first = e.errors()[0] if e.errors() else {}
    loc = ".".join(str(p) for p in first.get("loc", []) if p not in ("body", "query"))
    return JSONResponse(errors.validation(f"{loc}: {first.get('msg', 'invalid request')}".strip(": ")).body(),
                        status_code=422)


# ---------- auth-less identity ----------
def uid(x_user_id: str | None = Header(default=None)) -> str:
    if not x_user_id or len(x_user_id) > 64:
        raise errors.validation("X-User-Id header is required.")
    return x_user_id


def current_user(user_id: str = Depends(uid)) -> dict:
    u = db.get("users", "user_id", user_id)
    if not u:
        raise errors.not_found("User not found. Create one with POST /users.")
    return u


# 1
@app.get("/health")
async def health():
    return {"status": "ok"}


# 2, 3
@app.post("/users")
async def create_user(body: UserIn, user_id: str = Depends(uid)):
    user = {"user_id": user_id, **body.model_dump()}
    db.put("users", "user_id", user_id, user)
    return user


@app.get("/users/me")
async def me(user: dict = Depends(current_user)):
    return user


# 4
@app.post("/vehicles/vision")
async def vehicle_vision(photo: UploadFile = File(...), _: str = Depends(uid)):
    return await vision.read_vehicle(photo)


# 5, 6
@app.post("/vehicles")
async def create_vehicle(body: VehicleIn, user: dict = Depends(current_user)):
    vid = f"veh_{uuid.uuid4().hex[:8]}"
    v = {"vehicle_id": vid, **body.model_dump(exclude_none=True), "plate": body.plate.upper(),
         "state": body.state.upper()}
    db.put("vehicles", "vehicle_id", vid, {**v, "_user_id": user["user_id"]}, user_id=user["user_id"])
    return v


@app.get("/vehicles")
async def list_vehicles(user: dict = Depends(current_user)):
    rows = db.query("SELECT data FROM vehicles WHERE user_id=? ORDER BY rowid", (user["user_id"],))
    return {"vehicles": [{k: v for k, v in json.loads(r["data"]).items() if not k.startswith("_")} for r in rows]}


# 7, 8
@app.get("/properties")
async def list_properties(lat: float, lng: float, limit: int = 10, _: str = Depends(uid)):
    return {"properties": properties.nearby(lat, lng, max(1, min(limit, 50)))}


@app.get("/properties/{property_id}")
async def get_property(property_id: str, _: str = Depends(uid)):
    return properties.public(properties.get_raw(property_id))


# 9-17
@app.post("/registrations/draft")
async def draft(body: DraftIn, user: dict = Depends(current_user)):
    return drafts.public(drafts.draft(user, body))


@app.patch("/registrations/{registration_id}")
async def patch(registration_id: str, body: PatchIn, user: dict = Depends(current_user)):
    return drafts.public(drafts.patch(user, registration_id, body))


@app.post("/registrations/{registration_id}/confirm")
async def confirm(registration_id: str, body: ConfirmIn | None = None, user: dict = Depends(current_user)):
    return drafts.public(drafts.confirm(user, registration_id, (body or ConfirmIn()).channel))


@app.post("/registrations/{registration_id}/cancel")
async def cancel(registration_id: str, user: dict = Depends(current_user)):
    return drafts.public(drafts.cancel(user, registration_id))


@app.get("/registrations/{registration_id}")
async def get_registration(registration_id: str, user: dict = Depends(current_user)):
    return drafts.public(drafts.load(registration_id, user["user_id"]))


@app.post("/registrations/{registration_id}/answer")
async def answer(registration_id: str, body: AnswerIn, user: dict = Depends(current_user)):
    return drafts.public(drafts.answer(user, registration_id, body.field, body.value))


@app.post("/registrations/{registration_id}/resume")
async def resume(registration_id: str, user: dict = Depends(current_user)):
    return drafts.public(drafts.resume(user, registration_id))


@app.post("/registrations/{registration_id}/renew")
async def renew(registration_id: str, body: RenewIn, user: dict = Depends(current_user)):
    return drafts.public(drafts.renew(user, registration_id, body.duration_hours))


@app.get("/passes")
async def passes(user: dict = Depends(current_user)):
    regs = drafts.list_for_user(user["user_id"], ("confirmed", "expired", "finished"))
    return {"passes": [drafts.public(r) for r in regs]}


# 18, 19
@app.post("/signs/analyze")
async def analyze_sign(photo: UploadFile = File(...), lat: float | None = Form(None), lng: float | None = Form(None),
                       user_id: str = Depends(uid)):
    return await signs.analyze(user_id, photo, lat, lng)


@app.post("/checkout/mock")
async def checkout(body: CheckoutIn, user: dict = Depends(current_user)):
    return signs.checkout(user, body.plan_id, body.amount_usd)


# 20 (called by Photon, not the app): verify signature, ack fast, work in the background
@app.post("/messaging/webhook")
async def webhook(request: Request):
    if not settings.photon_webhook_secret:
        return JSONResponse(errors.ApiError(500, "validation_error", "Webhook secret is not configured.").body(), 500)
    raw = await request.body()
    if not messaging.verify_signature(raw, request.headers.get("x-spectrum-timestamp"),
                                      request.headers.get("x-spectrum-signature")):
        return JSONResponse({"error": {"code": "validation_error", "message": "Invalid signature."}}, status_code=401)
    try:
        payload = json.loads(raw)
    except ValueError:
        return {"ok": True}
    messaging.spawn(messaging.handle_inbound(payload))
    return {"ok": True}
