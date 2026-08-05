"""Turn "the GPU node is not running" into an error that names the fix.

Without this, a stopped engine surfaces as a bare 500 from LiteLLM. A developer
reading that opens a bug against the gateway; what they actually need to do is
run `gpu-up`. The gateway itself is healthy in this state and keeps serving
/v1/models, which makes the 500 even more misleading.

Loaded via `litellm_settings.callbacks` in config.yaml. LiteLLM calls
async_post_call_failure_hook for every request that fails, and an exception
raised here replaces the response the client sees.
"""

from litellm.integrations.custom_logger import CustomLogger
from fastapi import HTTPException

# Substrings that mean "nothing is listening at the other end", as opposed to a
# model error, a rate limit, or a bad request. Matched case-insensitively
# against the exception text, because the engine being gone shows up as several
# different exception classes depending on where in the stack it is noticed.
_UNREACHABLE = (
    "connection error",
    "connection refused",
    "apiconnectionerror",
    "name or service not known",
    "nodename nor servname",
    "temporary failure in name resolution",
    "all connection attempts failed",
    "max retries exceeded",
    "cannot connect to host",
    "server disconnected",
    "no route to host",
    "network is unreachable",
)

_MESSAGE = (
    "Inference node is stopped or unreachable — the gateway is healthy, the GPU "
    "is not. Run `scripts/gpu-up.sh` and retry; it takes a few minutes for "
    "weights to load. If gpu-up reports no capacity, try the fallback region. "
    "This is not a gateway bug."
)


class EngineDownHandler(CustomLogger):
    async def async_post_call_failure_hook(
        self, request_data, original_exception, user_api_key_dict, traceback_str=None
    ):
        text = f"{type(original_exception).__name__} {original_exception}".lower()
        if any(needle in text for needle in _UNREACHABLE):
            # 503 rather than 500: the condition is temporary and the client is
            # not at fault. Retry-After is a hint, not a promise.
            raise HTTPException(
                status_code=503,
                detail={"error": {"message": _MESSAGE, "type": "engine_unavailable"}},
                headers={"Retry-After": "300"},
            )
        # Anything else is a real failure — let it through unchanged rather than
        # papering over model errors with a friendly message.
        return


proxy_handler_instance = EngineDownHandler()
