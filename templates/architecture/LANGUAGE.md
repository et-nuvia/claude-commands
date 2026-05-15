# Architecture Language

Shared vocabulary for `/arch-explore`, `/arch-grill`, `/arch-interfaces`. Use these terms exactly in every suggestion — don't substitute "component," "service," "API," or "boundary." Consistent language is the whole point.

## Terms

**Module** — anything with an interface and an implementation. Scale-agnostic: function, class, package, or tier-spanning slice. _Avoid_: unit, component, service.

**Interface** — everything a caller must know to use the module correctly: type signature, invariants, ordering constraints, error modes, required configuration, performance characteristics. _Avoid_: API, signature (too narrow).

**Implementation** — what's inside a module. Distinct from **Adapter**: reach for "adapter" when the seam is the topic; "implementation" otherwise.

**Depth** — leverage at the interface: behaviour a caller (or test) can exercise per unit of interface they must learn. **Deep** = large behaviour behind small interface. **Shallow** = interface ≈ implementation.

**Seam** _(Feathers)_ — a place where you can alter behaviour without editing in that place. The *location* of a module's interface. Choosing where the seam goes is its own design decision. _Avoid_: boundary (DDD-overloaded).

**Adapter** — a concrete thing satisfying an interface at a seam. Describes role (slot filled), not substance.

**Leverage** — what callers get from depth. More capability per unit of interface learned.

**Locality** — what maintainers get from depth. Change, bugs, knowledge, verification concentrate in one place.

## Principles

- **Depth is a property of the interface, not the implementation.** A deep module can be internally composed of small, mockable, swappable parts — they just aren't part of the interface. Internal seams (private, test-only) are fine; don't expose them through the external interface.
- **The deletion test.** Imagine deleting the module. Complexity vanishes → it was a pass-through. Complexity reappears across N callers → it was earning its keep.
- **The interface is the test surface.** Callers and tests cross the same seam. Wanting to test *past* the interface = wrong module shape.
- **One adapter = hypothetical seam. Two adapters = real seam.** Don't introduce a port unless something actually varies across it (typically production + test).

## Rejected framings

- Depth as `implementation_lines / interface_lines` (Ousterhout) — rewards padding. Use depth-as-leverage.
- "Interface" as the TypeScript `interface` keyword or a class's public methods — too narrow.
- "Boundary" — DDD-overloaded. Say **seam** or **interface**.

## Source

Adapted from `mattpocock/skills/skills/engineering/improve-codebase-architecture/LANGUAGE.md`.
