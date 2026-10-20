/* capture-chrome.js: save the product's real page as a design round's chrome (claude-config#1364).

   Run in the MAIN session's browser (Playwright's browser_evaluate, with this file's text as the
   function), on the product's page, signed in as the person the screen is for, with the window at
   the width the round is drawn at. It answers with the page as one self contained document: the
   markup as it renders now, every stylesheet the page uses inlined, every font and image those
   stylesheets name inlined as data, and every script taken out (the chrome is drawn, never run).
   Save the answer as the round's chrome.html, and name it in the spec:

     "chrome": {"captured": "chrome.html", "from": "<the URL, who was signed in, the date>",
                "slot": "#<the id of the element the round draws into>", "width": <the window width>}

   A stylesheet the page cannot read (another origin's, without CORS) and a font or image that cannot
   be fetched are listed in the answer's first comment, never silently left out: a chrome missing its
   font draws in a fallback font, and every picture compared against it differs. */
async () => {
  const missing = [];
  const toData = async (url) => {
    try {
      const res = await fetch(url, { credentials: "include" });
      if (!res.ok) throw new Error("HTTP " + res.status);
      const blob = await res.blob();
      return await new Promise((ok, no) => {
        const r = new FileReader();
        r.onload = () => ok(r.result);
        r.onerror = () => no(r.error);
        r.readAsDataURL(blob);
      });
    } catch (e) {
      missing.push(url + " (" + String(e && e.message ? e.message : e) + ")");
      return null;
    }
  };
  const inlineUrls = async (css, base) => {
    const found = [...css.matchAll(/url\(\s*(['"]?)([^'")]+)\1\s*\)/g)];
    let out = css;
    for (const m of found) {
      const ref = m[2];
      if (ref.startsWith("data:") || ref.startsWith("#")) continue;
      const data = await toData(new URL(ref, base).href);
      if (data) out = out.split(m[0]).join('url("' + data + '")');
    }
    return out;
  };
  let css = "";
  for (const sheet of [...document.styleSheets]) {
    let rules;
    try {
      rules = [...sheet.cssRules];
    } catch (e) {
      missing.push((sheet.href || "an inline stylesheet") + " (its rules cannot be read from this page)");
      continue;
    }
    css += (await inlineUrls(rules.map((r) => r.cssText).join("\n"), sheet.href || location.href)) + "\n";
  }
  const root = document.documentElement.cloneNode(true);
  root.querySelectorAll("script, noscript, link[rel~='stylesheet'], link[rel='preload'], link[rel='modulepreload'], style").forEach((n) => n.remove());
  for (const img of root.querySelectorAll("img[src]")) {
    const src = img.getAttribute("src");
    if (src.startsWith("data:")) continue;
    const data = await toData(new URL(src, location.href).href);
    if (data) { img.setAttribute("src", data); img.removeAttribute("srcset"); }
  }
  const style = document.createElement("style");
  style.textContent = css;
  root.querySelector("head").append(style);
  const note = "<!-- captured from " + location.href + " at " + window.innerWidth + " wide on " + new Date().toISOString() +
    (missing.length ? "; NOT inlined, so drawn without: " + missing.join("; ") : "; every stylesheet, font and image inlined") + " -->";
  return "<!doctype html>\n" + note + "\n" + root.outerHTML;
}
