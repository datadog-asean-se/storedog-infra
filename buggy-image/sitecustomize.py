"""Fault injection for the storedog `discounts` demo image.

Python auto-imports `sitecustomize` at startup when its directory is on sys.path
(we set PYTHONPATH=/faults in the Dockerfile). We monkeypatch Flask.wsgi_app to add
a latency regression and a burst of 5xx errors, so that Datadog Watchdog APM Faulty
Deployment Detection flags this version and the Deployment Gate fails.

Tunable via env:
  FAULT_LATENCY_MS  - added latency per request in ms (default 600)
  FAULT_ERROR_RATE  - fraction of requests returned as HTTP 500 (default 0.25)
"""
import os
import random
import time

try:
    from flask import Flask

    _added_latency = float(os.getenv("FAULT_LATENCY_MS", "600")) / 1000.0
    _error_rate = float(os.getenv("FAULT_ERROR_RATE", "0.25"))
    _orig_wsgi_app = Flask.wsgi_app

    def _faulty_wsgi_app(self, environ, start_response):
        # Latency regression on every request.
        time.sleep(_added_latency)
        # Error-rate regression on a fraction of requests.
        if random.random() < _error_rate:
            body = b'{"error":"injected fault (demo buggy build)"}'
            start_response(
                "500 INTERNAL SERVER ERROR",
                [("Content-Type", "application/json"),
                 ("Content-Length", str(len(body)))],
            )
            return [body]
        return _orig_wsgi_app(self, environ, start_response)

    Flask.wsgi_app = _faulty_wsgi_app
    print(f"[buggy-build] fault injection active: +{_added_latency*1000:.0f}ms, "
          f"{_error_rate*100:.0f}% 5xx", flush=True)
except Exception as exc:  # never crash the app because of the fault shim
    print(f"[buggy-build] fault injection failed to load: {exc}", flush=True)
