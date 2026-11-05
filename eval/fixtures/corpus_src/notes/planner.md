# Planner

## Phase 1 — rates in the database — PLANNED

Move the rate tables out of the Lua file and into the database, so finance can change a price
without a deploy. Each change is dated, and the worker reads the rate valid at the event's date.

## Decision: keep the queue persistent

We keep the usage queue persistent even though it costs a disk write per event, because the
alternative lost two hours of events during the last outage.
