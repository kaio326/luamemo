# Alpha

Alpha is a small billing service that turns usage events into invoices for the finance team.

## Install

Run the installer, then restart the billing worker so that the new rate tables are loaded and
every pending invoice is recalculated with them.

## Configuration

Rates live in `config/rates.lua`. A missing rate falls back to the default plan, and the worker
logs a warning every time it does, so that finance can see which customers still need one.
