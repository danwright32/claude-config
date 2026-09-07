function buildScreen(variant) {
  var win = document.createElement("div");
  win.className = "win " + variant.key;
  var head = document.createElement("div");
  head.className = "hd";
  head.textContent = "Invoices";
  win.append(head);
  for (var i = 1; i <= 4; i++) {
    var row = document.createElement("div");
    row.className = "row " + (variant.density || "normal");
    row.textContent = "Client " + i + "   Oct " + i + "   $" + (i * 250);
    win.append(row);
  }
  return win;
}
