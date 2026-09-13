# <Project> — design

The entry point for the design. [`CLAUDE.md`](../CLAUDE.md) sends every agent here first; this file
states the core of the design and maps the companion docs, so a reader who finishes it knows what
the project is, why it is shaped this way, and where to look next.

Only **settled** facts live here. Routing rules for everything else:

- An open question, or a decision that may still be reversed → [`decisions.md`](decisions.md).
- A tunable knob or build constant → [`configuration.md`](configuration.md).
- A style rule with no rationale of its own → [`conventions.md`](conventions.md).
- A fact about one subsystem that this file only needs to point at → its own doc under `docs/`,
  listed under [Companion docs](#companion-docs).

A design decision is a doc edit, not a ticket note: when something here changes, change this file.

---

## The problem

<What is broken, missing, or too expensive today, stated without reference to the solution.>

### Who it is for

<The people or systems that have the problem, and what they currently do about it.>

### Constraints

<The hard limits any solution must respect: environment, compatibility, budget, time, policy.>

### Non-goals

<What this project deliberately does not attempt, so nobody re-opens it by accident.>

## The bet

<The one wager the project makes: the claim that, if true, makes this approach the right one.>

### What has to be true

<The assumptions the bet rests on, each stated so it could be checked.>

### What would falsify it

<The observation that would mean the bet was wrong, and what the fallback is.>

## Principles

<One `###` per principle. Each states the rule and what it rules out; a principle that rules nothing
out is not one.>

### <Principle>

<Statement. What it rules out.>

## Architecture

### Components

<The major parts, one short paragraph each: what it owns, what it never does.>

### Boundaries and interfaces

<Where the parts meet: the contracts between them, and which side owns each contract.>

### Data flow

<What moves through the system, in what order, and where it is persisted.>

### Invariants

<The properties that must hold at every step. Anything a gate or guard enforces is named here.>

## Build sequencing

<The order in which the system is built, and why that order. Each stage says what lands, what it
proves about the bet, and what it unblocks.>

### <Stage>

<What lands. What it proves. What it unblocks.>

### Current state

<Which stage is in progress, and what is known to be incomplete.>

## Companion docs

- [`decisions.md`](decisions.md) — open decisions, deferred but not forgotten
- [`configuration.md`](configuration.md) — every tunable knob and build constant
- [`conventions.md`](conventions.md) — coding fiats with no independent rationale
- <add one line per additional design doc: path, and what it is the source of truth for>
