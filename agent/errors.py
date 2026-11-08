"""Contract error body: {"error": {"code", "message"}}."""


class ApiError(Exception):
    def __init__(self, status: int, code: str, message: str):
        self.status, self.code, self.message = status, code, message
        super().__init__(message)

    def body(self) -> dict:
        return {"error": {"code": self.code, "message": self.message}}


def validation(msg): return ApiError(422, "validation_error", msg)
def not_found(msg): return ApiError(404, "not_found", msg)
def wrong_state(msg): return ApiError(409, "wrong_state", msg)
def consent_required(): return ApiError(403, "consent_required", "Enable consent to let Parkour register for you.")
def unknown_domain(msg): return ApiError(400, "unknown_domain", msg)
def llm_unavailable(msg="The AI service is unavailable right now."): return ApiError(503, "llm_unavailable", msg)
def unauthorized(msg="Sign in required."): return ApiError(401, "unauthorized", msg)
def conflict(msg): return ApiError(409, "conflict", msg)
def unavailable(msg="Storage is unavailable right now. Try again shortly."): return ApiError(503, "storage_unavailable", msg)
