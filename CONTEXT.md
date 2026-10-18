# Pomo

A personal, local-only Pomodoro timer that runs natively on every device a user owns, keeps one shared history across them, and lets AI agents start timers and measure where time went.

## Language

**Block**:
One timed span of a single kind (focus, short break or long break) with a start, a planned end and an outcome.
_Avoid_: Pomodoro (as a unit of record), session, round, interval

**Focus block**:
A block of work time. The only kind that counts toward focus statistics.
_Avoid_: Work session, sprint

**Cycle**:
A run of focus blocks and breaks that ends in a long break.
_Avoid_: Set, round

**Timer**:
The single live state that says which block is running, paused or idle, and when it ends. There is exactly one Timer across all devices.
_Avoid_: Clock, countdown

**Label**:
Free text on a block naming what the work was.
_Avoid_: Task, title, project

**Project**:
An optional grouping of labels for statistics.
_Avoid_: Category, folder

**Command**:
A request to change the Timer (start, pause, resume, extend, skip, reset, stop). Issued by a person or an agent.
_Avoid_: Action, intent, request

**Event**:
An immutable fact that a command produced, such as a block started or completed. Events are the only source of truth.
_Avoid_: Change, update, record

**Source**:
Who issued a command: a person on a device, or a named agent.
_Avoid_: Actor, author, origin

**Device**:
One installation of Pomo with its own identity key. Devices are peers; none is the server.
_Avoid_: Client, node, instance

**Pairing**:
The one-time act of making two Devices trust each other.
_Avoid_: Linking, enrolling

**Sync**:
Two Devices exchanging the Events one has and the other lacks until both hold the same set.
_Avoid_: Replication, backup

**Projection**:
State or statistics derived from Events. Can always be rebuilt and is never edited.
_Avoid_: Cache, view, snapshot

**Daemon**:
The headless Mac process that owns the Mac's store, syncs, and serves agents, with or without the menu bar app open.
_Avoid_: Server, backend, service

**Agent**:
An AI assistant that reads Pomo data and issues Commands through the Daemon.
_Avoid_: Bot, integration, plugin

**Shell**:
The native UI of one platform, wrapped around the shared core.
_Avoid_: Frontend, client, wrapper

**Core**:
The shared Rust library that holds the timer rules, storage, Sync and agent API logic.
_Avoid_: Engine, SDK, backend
