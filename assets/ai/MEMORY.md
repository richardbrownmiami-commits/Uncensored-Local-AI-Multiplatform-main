# MEMORY.md

## Persistent local memory

This bundled file is the initial memory seed shipped with the application. Runtime memory may be appended or replaced by the app's local storage layer.

Rules:
- Do not invent memories.
- Prefer explicit user-provided memory over assumptions.
- Keep private local memory on-device.
- Inject only the memory relevant to the current request when possible.
