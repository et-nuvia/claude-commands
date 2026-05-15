# Deepening

How to deepen a cluster of shallow modules safely, given its dependencies. Vocabulary from [LANGUAGE.md](LANGUAGE.md).

## Dependency categories

Classify each candidate's dependencies — determines how the deepened module is tested across its seam.

### 1. In-process
Pure computation, in-memory state, no I/O. Always deepenable — merge the modules, test through the new interface directly. No adapter.

### 2. Local-substitutable
Dependencies w/ local test stand-ins (PGLite for Postgres, in-memory FS). Deepenable if the stand-in exists. Test w/ stand-in running in the suite. Seam is internal; no port at the external interface.

### 3. Remote but owned (Ports & Adapters)
Your own services across a network boundary (microservices, internal APIs). Define a **port** at the seam. Deep module owns the logic; transport injected as an **adapter**. Tests use in-memory adapter; production uses HTTP/gRPC/queue adapter.

Recommendation shape: *"Define a port at the seam, implement an HTTP adapter for production and an in-memory adapter for testing, so the logic sits in one deep module even though it's deployed across a network."*

### 4. True external (Mock)
Third-party services (Stripe, Twilio) you don't control. Deepened module takes the external dep as an injected port; tests provide a mock adapter.

## Seam discipline

- **One adapter = hypothetical seam. Two adapters = real one.** Don't introduce a port unless ≥2 adapters justified (typically production + test). Single-adapter seam is just indirection.
- **Internal seams vs external seams.** A deep module can have internal seams (private, used by its own tests) as well as the external seam at its interface. Don't expose internal seams through the interface just because tests use them.

## Testing strategy: replace, don't layer

- Old unit tests on shallow modules become waste once interface-level tests exist — delete them.
- Write new tests at the deepened module's interface. **Interface is the test surface.**
- Assert observable outcomes through the interface, not internal state.
- Tests should survive internal refactors. If a test has to change when the implementation changes, it's testing past the interface.

## Source

Adapted from `mattpocock/skills/skills/engineering/improve-codebase-architecture/DEEPENING.md`.
