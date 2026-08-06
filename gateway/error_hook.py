"""Turn "the GPU node is not running" into an error each audience can act on.

Without this, a stopped engine surfaces as a bare 500 from LiteLLM. A developer
reading that opens a bug against the gateway. The gateway itself is healthy in
this state and keeps serving /v1/models, which makes the 500 even more
misleading.

Two audiences, deliberately split:
  - the RESPONSE is for developers, who cannot and should not run
    infrastructure commands — it says the model is down, retrying is fine, and
    who to poke if it stays down;
  - the gateway LOG carries the operator detail (gpu-up.sh, capacity,
    cold-start timing), because whoever can act on that has log access.
Putting admin instructions in the client response quietly implied every
developer holds the provider credentials, which is exactly the split
scripts/.env exists to prevent.

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

# What a developer sees. No infra commands, no provider vocabulary.
_MESSAGE = (
    "The model backend is currently offline. It may be starting up — retry in "
    "a few minutes. If this persists, tell whoever runs your gateway."
)

# What the operator sees, in `docker compose logs litellm`.
_OPERATOR_LOG = (
    "engine unreachable — the gateway is healthy, the GPU node is not. "
    "Run `scripts/gpu-up.sh`; cold start takes minutes. If it reports no "
    "capacity, see `gpu-up.sh --list-gpus`. Not a gateway bug."
)


class EngineDownHandler(CustomLogger):
    async def async_post_call_failure_hook(
        self, request_data, original_exception, user_api_key_dict, traceback_str=None
    ):
        text = f"{type(original_exception).__name__} {original_exception}".lower()
        # The node's failure endpoint (provision.sh) answers 503 with a full
        # diagnostic body when vLLM has died. LiteLLM relays that upstream body
        # into the exception text — tracebacks, engine config, all of it. That
        # is operator material: log it verbatim here, and hand the developer
        # the same calm message as any other outage. Matched FIRST, because it
        # also contains none of the connection-error needles below.
        if "engine_failed_to_start" in text:
            print(f"[engine-down] engine process died on the node; diagnostic from the failure endpoint follows", flush=True)
            print(f"[engine-down] {original_exception}", flush=True)
            print(f"[engine-down] {_OPERATOR_LOG}", flush=True)
            raise HTTPException(
                status_code=503,
                detail={"error": {"message": _MESSAGE, "type": "engine_unavailable"}},
                headers={"Retry-After": "300"},
            )
        if any(needle in text for needle in _UNREACHABLE):
            # stdout -> `docker compose logs litellm`. The operator detail goes
            # here, where only operators can read it.
            print(f"[engine-down] {_OPERATOR_LOG}", flush=True)
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
