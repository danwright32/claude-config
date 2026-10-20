// Draws only what goes in the product's slot: the chrome around it (the header) is the product's
// own, captured in chrome.html, and the rows come from the round's fixture.
function buildScreen(variant) {
  var list = document.createElement("div");
  list.className = "list";
  window.DESIGN_FIXTURE.invoices.forEach(function (invoice) {
    var row = document.createElement("div");
    row.className = "row " + (variant.density || "normal");
    row.textContent = invoice.client + "   " + invoice.date + "   $" + invoice.amount;
    list.append(row);
  });
  return list;
}
