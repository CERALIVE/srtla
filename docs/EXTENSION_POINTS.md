# Receiver Extension Points

This document describes the **service-primitive extension points** on the
`srtla_rec` receiver: stable seams a future multi-tenant / routing service layer
can install without forking the data path.

For protocol internals and the connection-group lifecycle these hooks observe,
see [How SRTLA Works](HOW_IT_WORKS.md). For quick-start usage, see the
[README](../README.md).

> **Status:** groundwork only. In this build every extension point is **unset by
> default** and the receiver behaves exactly as a single-tenant relay — no extra
> call, no extra log, no allocation. Nothing here changes the single shared SRT
> target. The seams exist so a later service layer can attach *without* a
> behavior-changing diff to the receiver core.

## Table of Contents

- [GroupIdentity](#groupidentity)
- [Lifecycle hooks](#lifecycle-hooks)
- [Stream-id awareness](#stream-id-awareness)
- [Guarantees](#guarantees)
- [Usage sketch](#usage-sketch)

---

## GroupIdentity

`GroupIdentity` (in [`src/connection/connection_group.h`](../src/connection/connection_group.h))
is an immutable **snapshot** of the stable facts a routing/tenancy layer would
key on. It is pure data — it carries no behavior, and nothing in this build
consults `external_id`.

```cpp
struct GroupIdentity {
    std::string short_id;                                // first 4 id bytes as hex
    std::chrono::steady_clock::time_point registered_at; // group construction time
    std::vector<std::string> source_addresses;           // IP strings of current links
    std::string external_id;                             // opaque slot, empty by default
};
```

| Field | Meaning |
|-------|---------|
| `short_id` | Low-cardinality, greppable handle: the first four group-id bytes as hex. Matches `ConnectionGroup::short_id()` used by the Task 15 lifecycle logs. |
| `registered_at` | `steady_clock` timestamp captured at group construction. |
| `source_addresses` | IP strings of the group's current links. Rebuilt on every `identity()` call from the live connections, falling back to `last_address` **before** conn 0 joins and **after** the last link is reaped — so a snapshot always carries **≥1** source. |
| `external_id` | Opaque slot for a future service layer (e.g. a tenant/stream key). **Empty by default**; settable via `ConnectionGroup::set_external_id()`. The receiver core never reads it. |

Obtain a snapshot with `ConnectionGroup::identity()`. The snapshot is taken by
value, so a hook may retain it past the group's lifetime.

---

## Lifecycle hooks

Two `std::function` members on `ConnectionRegistry`
([`src/connection/connection_registry.h`](../src/connection/connection_registry.h))
fire at group registration and teardown. They follow the same callback idiom as
`cleanup_inactive(ts, cb)`.

```cpp
std::function<void(const GroupIdentity &)> on_group_registered;
std::function<void(const GroupIdentity &)> on_group_reaped;
```

| Hook | Fires when | Fires how often |
|------|-----------|-----------------|
| `on_group_registered` | A group is added to the registry (`add_group`), i.e. right after the REG2 reply is sent on the receiver registration path. | Once per registered group. |
| `on_group_reaped` | A group is torn down — both the idle-timeout reaper in `cleanup_inactive` **and** the explicit `remove_group` path. | Exactly once per teardown; a repeat teardown of an already-removed group is a no-op and does **not** re-fire. |

When a hook is unset (the default) the registry takes no extra action. These
hooks are designed to *observe* the same lifecycle moments the Task 15 structured
events already log (`group_registered`, `group_reaped`); they do not add log
lines of their own.

---

## Stream-id awareness

`stream_id_resolver` is a **declared extension point only**. It exists to document
where future routing metadata would be resolved — a multi-target receiver could
map a `GroupIdentity` to a per-group SRT target or stream key.

```cpp
std::function<std::optional<std::string>(const GroupIdentity &)> stream_id_resolver;
```

**The current single-target receiver never consults it.** A full
register → teardown lifecycle invokes the resolver zero times, and its return
value (even if installed) is ignored. The single shared SRT target is preserved
unchanged. This is the contract a future routing layer extends; today it is a
documented seam, not a behavior.

---

## Guarantees

- **Zero behavior change by default.** With no hook installed, the receiver is
  byte-identical to the pre-hook build (locked by
  [`tests/test_identity_hooks.cpp`](../tests/test_identity_hooks.cpp)).
- **No data-path involvement.** The hooks live on the registry's
  register/teardown path only. The SRT forwarding path and target resolution are
  untouched.
- **Fire-once teardown.** `remove_group` uses find-then-erase so a duplicate
  teardown cannot double-fire `on_group_reaped`.
- **Observe, don't drive.** Hooks receive an identity snapshot by value; they
  cannot alter the group trajectory.

---

## Usage sketch

A future service layer installs the hooks once, after constructing the registry
and before the receive loop starts. This is illustrative — no such installer
ships in this build.

```cpp
using srtla::connection::ConnectionRegistry;
using srtla::connection::GroupIdentity;

auto &registry = ConnectionRegistry::instance();

// Observe registrations (e.g. publish a "tenant online" service event).
registry.on_group_registered = [](const GroupIdentity &id) {
    service::publish_group_online(id.short_id,
                                  id.source_addresses,
                                  id.registered_at);
};

// Observe teardowns (mirror of the above).
registry.on_group_reaped = [](const GroupIdentity &id) {
    service::publish_group_offline(id.short_id);
};

// Future routing: resolve a per-group SRT target / stream key.
// The current receiver IGNORES the return — installing this changes nothing.
registry.stream_id_resolver = [](const GroupIdentity &id) -> std::optional<std::string> {
    return service::lookup_stream_target(id.external_id);
};
```

When that routing layer lands, the only receiver-core change required is to start
*consulting* `stream_id_resolver` at the forwarding site — the identity snapshot,
the lifecycle hooks, and the `external_id` slot are already in place.
