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
   font draws in a fallback font, and every picture compared against it differs.

   A theme on <html> (data-theme, a "dark" or "light" class, an inline color-scheme) that the page's
   own script set is taken out, so the chrome follows the same theme rule as the built page rather
   than whichever theme the capture ran in (claude-config#2045); one in the markup the server sent is
   kept. The first comment names either, and says so when the served markup could not be read. */
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
  // The theme on <html> follows the same rule as the page it came from (claude-config#2045). A theme
  // the page's own boot script stamped there (from a stored preference, a cookie, the clock) is put
  // back as the server sent it, since the chrome is drawn with every script out and the build follows
  // whoever is signed in; a theme in the served markup itself is kept, since the build is served the
  // same way. Either way the first comment names what was taken out or what the chrome is pinned to.
  const themeMarks = (el) => {
    const marks = [];
    if (el.hasAttribute("data-theme")) marks.push('data-theme="' + el.getAttribute("data-theme") + '"');
    for (const c of ["dark", "light"]) if (el.classList.contains(c)) marks.push('class "' + c + '"');
    if (el.style && el.style.colorScheme) marks.push("color-scheme: " + el.style.colorScheme);
    return marks;
  };
  let themeNote = "";
  const liveMarks = themeMarks(document.documentElement);
  let served = null;
  let unread = "";
  try {
    const res = await fetch(location.href, { credentials: "include" });
    if (!res.ok) throw new Error("HTTP " + res.status);
    served = new DOMParser().parseFromString(await res.text(), "text/html").documentElement;
  } catch (e) {
    unread = String(e && e.message ? e.message : e);
  }
  if (served) {
    if (served.hasAttribute("data-theme")) root.setAttribute("data-theme", served.getAttribute("data-theme"));
    else root.removeAttribute("data-theme");
    for (const c of ["dark", "light"]) root.classList.toggle(c, served.classList.contains(c));
    if (!root.getAttribute("class")) root.removeAttribute("class");
    root.style.colorScheme = served.style.colorScheme || "";
    if (!root.getAttribute("style")) root.removeAttribute("style");
    const servedMarks = themeMarks(served);
    const stamped = liveMarks.filter((m) => !servedMarks.includes(m));
    if (stamped.length) themeNote += "; theme the page's script set on <html> taken out: " + stamped.join(", ");
    if (servedMarks.length) themeNote += "; theme pinned by the served page's own <html>, so kept: " + servedMarks.join(", ");
  } else if (liveMarks.length) {
    themeNote = "; theme pinned on <html>, kept because the served page could not be read to tell whether its script set it (" +
      unread + "): " + liveMarks.join(", ");
  }
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
    (missing.length ? "; NOT inlined, so drawn without: " + missing.join("; ") : "; every stylesheet, font and image inlined") + themeNote + " -->";
  return "<!doctype html>\n" + note + "\n" + root.outerHTML;
}
