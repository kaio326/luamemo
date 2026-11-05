# Use a persistent queue for usage events

We decided to put usage events on a persistent queue instead of writing invoices inline,
because a billing outage must never lose an event and the worker can then replay them.
