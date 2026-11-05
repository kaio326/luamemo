"""A second copy of the monthly summary, kept for the legacy exporter."""


def legacy_monthly_total(invoices, month):
    """Return the sum of the invoices issued in the given month."""
    return sum(i["total"] for i in invoices if i["month"] == month)
