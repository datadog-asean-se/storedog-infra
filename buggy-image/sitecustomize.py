"""Fault injection for the storedog `discounts` demo image.

Python auto-imports `sitecustomize` at startup when its directory is on sys.path
(we set PYTHONPATH=/faults in the Dockerfile). We register a Flask `before_request`
hook that adds latency and, on a fraction of requests, aborts with a 500 - so that
Datadog Watchdog APM Faulty Deployment Detection flags this version and the
Deployment Gate fails.

IMPORTANT - why `before_request` + `abort()`, not a `Flask.wsgi_app` monkeypatch:
an earlier version of this file directly monkeypatched `Flask.wsgi_app` and called
`start_response()` itself to short-circuit the 500 response. That bypasses Flask's
(and therefore ddtrace's Flask integration's) normal request/exception lifecycle
entirely - found live, via the Datadog API, that those injected 500s were not being
recorded as APM errors at all (near-zero error spans for the canary version despite
real, repeated 500 responses observed at the HTTP client). `app.before_request` and
`flask.abort()` run *inside* Flask's normal dispatch (through
`full_dispatch_request`/`handle_user_exception`), which is exactly what ddtrace's
Flask integration instruments - so the resulting span is correctly tagged as an
error with `http.status_code=500`.

Tunable via env:
  FAULT_LATENCY_MS  - added latency per request in ms (default 600)
  FAULT_ERROR_RATE  - fraction of requests aborted as HTTP 500 (default 0.25)
"""
import os
import random
import time

try:
    from flask import Flask, abort

    _added_latency = float(os.getenv("FAULT_LATENCY_MS", "600")) / 1000.0
    _error_rate = float(os.getenv("FAULT_ERROR_RATE", "0.25"))
    _orig_init = Flask.__init__

    def _patched_init(self, *args, **kwargs):
        _orig_init(self, *args, **kwargs)

        @self.before_request
        def _inject_fault():
            # Latency regression on every request.
            time.sleep(_added_latency)
            # Error-rate regression on a fraction of requests. abort() raises a
            # werkzeug HTTPException, which flows through Flask's normal
            # exception handling (and therefore ddtrace's Flask integration),
            # so the resulting span is correctly tagged as an error.
            if random.random() < _error_rate:
                abort(500, description="injected fault (demo buggy build)")

    Flask.__init__ = _patched_init
    print(f"[buggy-build] fault injection active: +{_added_latency*1000:.0f}ms, "
          f"{_error_rate*100:.0f}% 5xx (via before_request/abort, ddtrace-visible)",
          flush=True)
except Exception as exc:  # never crash the app because of the fault shim
    print(f"[buggy-build] fault injection failed to load: {exc}", flush=True)
