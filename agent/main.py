"""Parkour API (FastAPI). Endpoint paths and shapes follow API_CONTRACT.md section 5."""
import asyncio
import hmac
import json
import logging
import re
import shutil
import uuid
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, File, Form, Header, Request, UploadFile
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles

from . import auth, db, errors, store as store_mod
from .config import settings
from .models import (AnswerIn, CheckoutIn, ConfirmIn, DraftIn, MaverickIn, PasswordIn, PatchIn, PlaceLabelIn,
                     RenewIn, SignInIn, SignUpIn, UserIn, UserPatch, VehicleIn)
from .services import data, drafts, maverick, messaging, properties, reminders, runner, signs, vision, worker

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(message)s")


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings.proofs_dir.mkdir(parents=True, exist_ok=True)
    db.conn()
    properties.load_into_db()
    try:
        s = store_mod.get_store()
        s.load_properties(data.properties())  # the module checks these rules when drafting
        s.purge_expired_sessions()
    except Exception as e:  # storage may be down at boot; requests will report it
        logging.getLogger("parkour").warning("startup storage setup skipped: %s", type(e).__name__)
    tasks = [asyncio.create_task(reminders.loop()), asyncio.create_task(worker.loop())]
    yield
    for t in tasks:
        t.cancel()
    # Stop browser runs still in flight so shutdown never waits on a browser.
    running = list(runner._running)
    for t in running:
        t.cancel()
    await asyncio.gather(*tasks, *running, return_exceptions=True)


app = FastAPI(title="Parkour API", lifespan=lifespan)
# No cookies or auth headers beyond X-User-Id, so any origin is safe; lets `flutter run -d chrome` call the API directly.
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])
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


@app.exception_handler(store_mod.StoreUnavailable)
async def storage_down(_: Request, e: store_mod.StoreUnavailable):
    return JSONResponse(errors.unavailable().body(), status_code=503)


# ---------- identity ----------
# Signed-in people send `Authorization: Bearer <token>`. Anonymous devices may still send X-User-Id
# (unless REQUIRE_AUTH=true), but an id that belongs to an account always needs the token.
USER_ID_RE = auth.USER_ID_RE


def bearer(authorization: str | None) -> str | None:
    if authorization and authorization.lower().startswith("bearer "):
        return authorization[7:].strip()
    return None


def uid(authorization: str | None = Header(default=None), x_user_id: str | None = Header(default=None)) -> str:
    if (token := bearer(authorization)):
        return auth.resolve(token)
    if settings.require_auth:
        raise errors.unauthorized()
    if not x_user_id or not USER_ID_RE.match(x_user_id):
        raise errors.validation("X-User-Id header is required.")
    if store_mod.get_store().get_credential(user_id=x_user_id):
        raise errors.unauthorized("This account needs you to sign in.")
    return x_user_id


def current_user(user_id: str = Depends(uid)) -> dict:
    u = store_mod.get_store().get_user(user_id)
    if not u:
        raise errors.not_found("User not found. Create one with POST /users.")
    return u


def user_out(u: dict) -> dict:
    return {**u, "has_account": store_mod.get_store().get_credential(user_id=u["user_id"]) is not None}


# 1
@app.get("/health")
async def health():
    return {"status": "ok"}


# 2, 3
@app.post("/users")
async def create_user(body: UserIn, user_id: str = Depends(uid)):
    user = {"user_id": user_id, **body.model_dump()}
    store_mod.get_store().put_user(user)
    return user_out(user)


@app.get("/users/me")
async def me(user: dict = Depends(current_user)):
    return user_out(user)


# 23-27: accounts
def session_out(user: dict, token: str, expires_at: str) -> dict:
    return {"user": user_out(user), "token": token, "expires_at": expires_at}


@app.post("/auth/signup")
async def signup(body: SignUpIn, x_user_id: str | None = Header(default=None)):
    email = auth.normalize_email(body.email)
    auth.check_password(body.password)
    s = store_mod.get_store()
    if s.get_credential(email=email):
        raise errors.conflict("An account with that email already exists. Sign in instead.")
    # An anonymous device keeps its cars and history when it signs up.
    claim = x_user_id if (x_user_id and USER_ID_RE.match(x_user_id) and s.get_user(x_user_id)
                          and not s.get_credential(user_id=x_user_id)) else None
    user_id = claim or str(uuid.uuid4())
    try:
        s.create_credential(user_id, email, auth.hash_password(body.password))
    except store_mod.EmailTaken:
        raise errors.conflict("An account with that email already exists. Sign in instead.")
    user = {"user_id": user_id, "name": body.name, "phone": body.phone, "email": email,
            "consent_register": body.consent_register, "spending_cap_usd": body.spending_cap_usd,
            "notify_channel": body.notify_channel}
    s.put_user(user)
    token, exp = auth.new_session(user_id)
    return session_out(user, token, exp)


@app.post("/auth/signin")
async def signin(body: SignInIn):
    user_id = auth.authenticate(body.email, body.password)
    s = store_mod.get_store()
    user = s.get_user(user_id)
    if not user:
        raise errors.not_found("Account has no profile.")
    token, exp = auth.new_session(user_id)
    return session_out(user, token, exp)


@app.post("/auth/signout")
async def signout(authorization: str | None = Header(default=None)):
    if (token := bearer(authorization)):
        store_mod.get_store().delete_session(auth.token_hash(token))
    return {"ok": True}


@app.post("/auth/password")
async def change_password(body: PasswordIn, authorization: str | None = Header(default=None),
                          user: dict = Depends(current_user)):
    s = store_mod.get_store()
    cred = s.get_credential(user_id=user["user_id"])
    if not cred or not auth.verify_password(body.current_password, cred["password_hash"]):
        raise errors.unauthorized("Current password is wrong.")
    auth.check_password(body.new_password)
    s.set_password(user["user_id"], auth.hash_password(body.new_password))
    s.delete_other_sessions(user["user_id"], auth.token_hash(bearer(authorization) or ""))  # sign out other devices
    return {"ok": True}


@app.patch("/users/me")
async def patch_me(body: UserPatch, user: dict = Depends(current_user)):
    user = {**user, **body.model_dump(exclude_none=True)}
    store_mod.get_store().put_user(user)
    return user_out(user)


@app.delete("/users/me")
async def delete_me(user: dict = Depends(current_user)):
    """Removes the profile, account, cars, saved places, history and registrations for this person."""
    for r in store_mod.get_store().list_registrations(user["user_id"]):
        shutil.rmtree(settings.proofs_dir / r["registration_id"], ignore_errors=True)
    db.execute("DELETE FROM plans WHERE user_id=?", (user["user_id"],))
    store_mod.get_store().delete_user(user["user_id"])
    return {"ok": True}


# 28-30: remembered parking
@app.get("/places")
async def list_places(property_id: str | None = None, user: dict = Depends(current_user)):
    return {"places": store_mod.get_store().list_places(user["user_id"], property_id)}


@app.patch("/places/{place_id}")
async def label_place(place_id: str, body: PlaceLabelIn, user: dict = Depends(current_user)):
    if not store_mod.get_store().label_place(user["user_id"], place_id, body.label.strip()):
        raise errors.not_found("Saved place not found.")
    return next(p for p in store_mod.get_store().list_places(user["user_id"]) if p["place_id"] == place_id)


@app.delete("/places/{place_id}")
async def forget_place(place_id: str, user: dict = Depends(current_user)):
    store_mod.get_store().forget_place(user["user_id"], place_id)
    return {"ok": True}


@app.get("/history")
async def history(limit: int = 50, user: dict = Depends(current_user)):
    return {"history": store_mod.get_store().list_history(user["user_id"], max(1, min(limit, 200)))}


# 4
@app.post("/vehicles/vision")
async def vehicle_vision(photo: UploadFile = File(...), _: str = Depends(uid)):
    return await vision.read_vehicle(photo)


# 5, 6
@app.post("/vehicles")
async def create_vehicle(body: VehicleIn, user: dict = Depends(current_user)):
    v = {"vehicle_id": f"veh_{uuid.uuid4().hex[:8]}", **body.model_dump(exclude_none=True),
         "plate": body.plate.upper(), "state": body.state.upper()}
    store_mod.get_store().put_vehicle(user["user_id"], v)
    return {k: val for k, val in v.items()}


@app.get("/vehicles")
async def list_vehicles(user: dict = Depends(current_user)):
    return {"vehicles": [{k: v for k, v in x.items() if k != "user_id"} for x in store_mod.get_store().list_vehicles(user["user_id"])]}


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


# 22: hard-coded Maverick Place guest parking. Poll the result with GET /registrations/{id}.
@app.post("/maverick-place/register")
async def maverick_register(body: MaverickIn, user: dict = Depends(current_user)):
    if not body.confirm:
        raise errors.validation("confirm must be true: the user has to approve the registration.")
    if not user.get("consent_register"):
        raise errors.consent_required()
    veh = store_mod.get_store().get_vehicle(body.vehicle_id)
    if not veh or veh["user_id"] != user["user_id"]:
        raise errors.not_found(f"Vehicle {body.vehicle_id} not found.")
    # An empty unit or resident name is filled from the last visit inside the module.
    reg = maverick.create(user, veh, body.unit, body.resident_last_name,
                          body.guest.model_dump(exclude_none=True) if body.guest else None, body.dry_run)
    return drafts.public(reg)


# 32: replies that the Photon sidecar receives over its own connection (no public webhook needed)
@app.post("/messaging/inbound")
async def inbound(request: Request, x_internal_key: str | None = Header(default=None)):
    key = settings.internal_api_key
    if not key or not hmac.compare_digest(x_internal_key or "", key):
        raise errors.unauthorized("Missing or bad X-Internal-Key.")
    body = await request.json()
    phone, text = str(body.get("from_phone") or ""), str(body.get("text") or "")
    if not re.match(r"^\+[1-9]\d{6,14}$", phone) or not text or len(text) > 1000:
        raise errors.validation("from_phone (E.164) and text (up to 1000 characters) are required.")
    messaging.spawn(messaging.handle_inbound({"message": {
        "id": body.get("message_id"), "direction": "inbound", "sender": {"id": phone},
        "content": {"type": "text", "text": text}}}))
    return {"ok": True}


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
