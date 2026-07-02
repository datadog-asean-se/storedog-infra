# Notice

This repository is an **internal Datadog Sales Engineering reference implementation**,
maintained by the ASEAN SE team, for demoing Datadog capabilities (Deployment Gates,
Argo Rollouts, Feature Flags) against the
[`datadog-asean-se/storedog`](https://github.com/datadog-asean-se/storedog) demo app.

- Not an officially supported Datadog product.
- Not intended for production use.
- Intentionally includes a "buggy" container build (`buggy-image/`) that injects
  latency and errors on purpose, for demo use only.

See [`storedog`](https://github.com/datadog-asean-se/storedog)'s own README for the
same caveat about its upstream app.
