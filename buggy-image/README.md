# Buggy discounts image (B5)

A dedicated image tag that injects a **latency + error-rate regression** into the
storedog `discounts` service, so the Deployment Gate's `faulty_deployment_detection`
rule reliably fails and Argo Rollouts auto-rolls-back.

## How it trips Faulty Deployment Detection

- `sitecustomize.py` monkeypatches `Flask.wsgi_app` to add ~600ms latency per request
  and return HTTP 500 on ~25% of requests.
- `BROKEN_DISCOUNTS=ENABLED` also activates the app's built-in random 500s on
  `/discount-code` (see upstream `services/discounts/discounts.py`).
- Watchdog APM Faulty Deployment Detection compares the new `version`'s latency/error
  profile against prior versions and flags the regression during the gate's evaluation
  window.

## Build & push

```bash
../scripts/build-and-push-buggy.sh   # builds :buggy (and a clean :good) and pushes
```

Tune the severity with build/runtime env: `FAULT_LATENCY_MS`, `FAULT_ERROR_RATE`.
