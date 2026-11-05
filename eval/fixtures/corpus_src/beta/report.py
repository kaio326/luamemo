"""Reports: monthly summaries of the invoices alpha produced."""


def monthly_total(invoices, month):
    """Return the sum of the invoices issued in the given month."""
    return sum(i["total"] for i in invoices if i["month"] == month)


def top_customers(invoices, n=5):
    """Return the n customers with the highest invoiced totals."""
    totals = {}
    for i in invoices:
        totals[i["customer"]] = totals.get(i["customer"], 0) + i["total"]
    return sorted(totals, key=totals.get, reverse=True)[:n]
