# nftables-structure-fuzzer

Structure-aware fuzzing environment for nftables userspace libraries (`libnftnl`, `libmnl`) built with Nix, MicroVM isolation, and reproducible containerized harnesses.

---

## What It Does

- Implements schema-aware fuzzing for netfilter attribute trees.
- Targets `libnftnl` and `libmnl` userspace normalization layers.
- Avoids blind byte-level mutation by modeling nftables structures explicitly.
- Runs fuzz targets inside reproducible Nix-based MicroVM environments.
- Builds and loads instrumented containers via `nix2container`.
- Orchestrates fuzz infrastructure using `divnix/std` and `process-compose`.
- Integrates Prometheus + Grafana for metrics collection.
- Supports libprotobuf-mutator-based structured mutation.
- Provides deterministic, flake-pinned development environments.

This repository models nftables as a structured AST problem rather than a raw byte stream.

---

## Architecture Overview

```
              ┌────────────────────────────┐
              │         Nix Flake          │
              │  (Reproducible Toolchain)  │
              └─────────────┬──────────────┘
                            │
                            ▼
                    divnix/std Build Graph
                            │
        ┌───────────────────┼───────────────────┐
        ▼                   ▼                   ▼
   Container Builds     MicroVM Config     Devshell Env
        │                   │                   │
        ▼                   ▼                   ▼
  nix2container        microvm.nix         std shell
        │                   │
        ▼                   ▼
  Fuzz Target VM   ←→   virtio daemon
        │
        ▼
  libnftnl / libmnl
        │
        ▼
 Prometheus → Grafana
```

---

## Process Orchestration

Uses `process-compose` to coordinate:

- Container image builds
- Container loads
- Compose stack startup
- VirtIO daemon startup
- MicroVM boot sequencing

Dependencies are enforced declaratively:

- Containers must build before load.
- VM waits on virtio readiness.
- Services wait on successful build completion.

This creates a reproducible fuzzing control plane.

---

## MicroVM Isolation

Fuzz targets execute inside `microvm.nix` environments:

- Isolated NixOS guest
- Serial console logging
- Deterministic boot
- Dedicated virtio communication layer
- Safe crash containment

Prevents host corruption during malformed netfilter payload execution.

---

## Structured Fuzzing Strategy

Traditional fuzzers mutate raw bytes.

This project:

- Models nftables netlink attribute trees.
- Generates semantically valid but structurally adversarial payloads.
- Uses libprotobuf-mutator for structured mutation.
- Focuses on userspace normalization boundaries.

This increases signal compared to blind mutation.

---

## Observability Stack

- Custom metrics exporter container.
- Prometheus collection.
- Grafana dashboarding.
- Process-level readiness detection.
- Log-based VM boot synchronization.

Fuzz campaigns can be monitored in real time.

---

## Tech Stack

- Nix flakes
- divnix/std
- flake-parts
- process-compose
- microvm.nix
- nix2container
- arion
- libprotobuf-mutator
- Nim
- libnftnl
- libmnl
- Prometheus
- Grafana

---

## Why This Is Interesting

This project demonstrates:

- Deep understanding of nftables userspace internals.
- Structured fuzzing beyond byte-level mutation.
- MicroVM-based isolation for crash containment.
- Fully reproducible fuzzing infrastructure via Nix.
- Declarative orchestration of multi-service fuzz environments.
- Cross-language integration (Nim, C libraries, Nix).

It treats fuzzing infrastructure as a first-class system, not just a binary harness.

---

## Development

Enter the std environment:

```bash
nix develop
```

This launches the `std` interactive environment.

From there, you can:

- Build containers
- Launch the MicroVM
- Start the process-compose stack
- Run fuzz campaigns

All dependencies are flake-pinned for deterministic builds.
