// ts-resolve.mjs <typescript dir>: what each identifier in a set of mods' source files refers to, as
// the TypeScript compiler's own checker resolves it (#895). Scope, shadowing, parameters, imports and
// where an expression ends are answered by the language, not by a hand written reader.
//
// Input on stdin: {"mods": [{"files": ["/abs/a.ts", ...]}, ...]}, one project per mod, so a name is
// never resolved into another mod. Output on stdout: {"/abs/a.ts": [[position, role, target], ...]}
// with positions in code points (the unit Python indexes a str by, where the compiler counts UTF-16
// units). role is "call" (the callee of a call), "decl" (the name a declaration gives), "short" (a
// shorthand property, `{ wait }`, whose target is the value it reads) or "ref".
// target is null when the checker finds no symbol, ["fn", file, start, end] for a function declared
// in the mod (start at its `function` keyword, or the `const`, `let` or `var` of its declaration),
// ["value", file, start, end] for any other variable the mod declares, ["other", file, start, end]
// for anything else the mod declares (a parameter, a class), and ["other"] for what it does not (a
// global). Every target with a file and start names one declaration, so two names resolve to the
// same thing exactly when those match (#915).
//
// Any failure to load the pinned compiler or to read a project exits non zero with the reason on
// stderr: the caller refuses rather than resolving nothing (L490).
import { mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const tsDir = process.argv[2];
if (!tsDir) {
  console.error("ts-resolve: no TypeScript folder given");
  process.exit(2);
}
// Imported by file URL from an absolute path: a relative folder would otherwise be read as a package
// name, and a folder with a space or a % in it as a broken URL (L740).
const base = resolve(tsDir, "node_modules", "typescript", "dist");
const load = (...parts) => import(pathToFileURL(join(base, ...parts)).href);
const { API } = await load("api", "sync", "api.js");
const { SyntaxKind } = await load("ast", "index.js");
const { SymbolFlags } = await load("enums", "symbolFlags.js");
// The kinds whose name an identifier gives, rather than reads: only these make it a "decl".
const DECLARATIONS = new Set([
  SyntaxKind.VariableDeclaration, SyntaxKind.FunctionDeclaration, SyntaxKind.FunctionExpression,
  SyntaxKind.Parameter, SyntaxKind.BindingElement, SyntaxKind.ClassDeclaration, SyntaxKind.ClassExpression,
  SyntaxKind.MethodDeclaration, SyntaxKind.PropertyDeclaration, SyntaxKind.PropertySignature,
  SyntaxKind.PropertyAssignment, SyntaxKind.GetAccessor, SyntaxKind.SetAccessor, SyntaxKind.InterfaceDeclaration,
  SyntaxKind.TypeAliasDeclaration, SyntaxKind.EnumDeclaration, SyntaxKind.EnumMember, SyntaxKind.ModuleDeclaration,
  SyntaxKind.ImportClause, SyntaxKind.ImportSpecifier, SyntaxKind.NamespaceImport, SyntaxKind.ExportSpecifier,
  SyntaxKind.TypeParameter,
].filter((k) => k !== undefined));

const input = JSON.parse(readFileSync(0, "utf8"));
const real = (p) => {
  try {
    return realpathSync(p);
  } catch {
    return p;
  }
};
const dir = mkdtempSync(join(tmpdir(), "ts-resolve-"));
const api = new API({ cwd: dir });
const out = {};
try {
  const configs = input.mods.map((mod, i) => {
    const config = join(dir, `mod${i}.tsconfig.json`);
    writeFileSync(
      config,
      JSON.stringify({
        compilerOptions: {
          allowJs: true,
          checkJs: false,
          noEmit: true,
          noLib: true,
          types: [],
          jsx: "preserve",
          module: "esnext",
          moduleResolution: "bundler",
          allowImportingTsExtensions: true,
        },
        files: mod.files,
      }),
    );
    return config;
  });
  const snapshot = api.updateSnapshot({ openProjects: configs });
  input.mods.forEach((mod, i) => {
    const project = snapshot.getProject(configs[i]);
    if (!project) throw new Error(`no project for ${mod.files[0] ?? "an empty mod"}`);
    const own = new Map(mod.files.map((f) => [real(f), f]));
    // A compiler position in a file as a code point offset into the file as written. The compiler
    // drops a leading byte order mark from its text (measured on 7.0.2), so its positions run one
    // UTF-16 unit short of the file's there; Python reads the mark as a character (#895).
    const units = new Map();
    const raw = (file) => {
      codePoint(file, 0);
      return units.get(file);
    };
    const codePoint = (file, at) => {
      if (!units.has(file)) {
        const text = readFileSync(file, "utf8");
        const sf = project.program.getSourceFile(file);
        const shift = text.startsWith("﻿") && !(sf && typeof sf.text === "string" && sf.text.startsWith("﻿")) ? 1 : 0;
        const map = new Int32Array(text.length + 1);
        let cp = 0;
        for (let u = 0; u < text.length; u++) {
          map[u] = cp;
          const c = text.charCodeAt(u);
          if (c >= 0xd800 && c <= 0xdbff && u + 1 < text.length) {
            map[++u] = cp;
          }
          cp++;
        }
        map[text.length] = cp;
        units.set(file, { text, map, shift });
      }
      const u = units.get(file);
      return u.map[at + u.shift];
    };
    const target = (symbol) => {
      if (!symbol) return null;
      if (symbol.flags & SymbolFlags.Alias) symbol = project.checker.getAliasedSymbol(symbol);
      for (const handle of symbol.declarations ?? []) {
        const d = handle.resolve(project);
        if (!d) continue;
        const file = own.get(real(d.getSourceFile().fileName));
        if (!file) continue;
        if (d.kind === SyntaxKind.FunctionDeclaration) {
          const { text, shift } = raw(file);
          // Found in the file as written, then handed back as the compiler's position.
          const kw = text.indexOf("function", d.getStart() + shift) - shift;
          return ["fn", file, codePoint(file, kw), codePoint(file, d.end)];
        }
        if (d.kind === SyntaxKind.VariableDeclaration) {
          let init = d.initializer;
          while (init && [SyntaxKind.ParenthesizedExpression, SyntaxKind.AsExpression, SyntaxKind.SatisfiesExpression, SyntaxKind.NonNullExpression, SyntaxKind.TypeAssertionExpression].includes(init.kind)) {
            init = init.expression;
          }
          const list = d.parent;
          const start = list && list.declarations && list.declarations.length === 1 ? list.getStart() : d.getStart();
          const isFn = init && (init.kind === SyntaxKind.ArrowFunction || init.kind === SyntaxKind.FunctionExpression);
          return [isFn ? "fn" : "value", file, codePoint(file, start), codePoint(file, d.end)];
        }
        // Where it is declared, so two declarations sharing a name are told apart (#915).
        return ["other", file, codePoint(file, d.getStart()), codePoint(file, d.end)];
      }
      return ["other"];
    };
    for (const file of mod.files) {
      const sf = project.program.getSourceFile(file);
      if (!sf) throw new Error(`${file} is not in its mod's program`);
      const ids = [];
      const walk = (n) => {
        if (n.kind === SyntaxKind.Identifier) ids.push(n);
        n.forEachChild(walk);
      };
      walk(sf);
      const symbols = ids.length ? project.checker.getSymbolAtPosition(file, ids.map((n) => n.getStart())) : [];
      out[file] = ids.map((n, i) => {
        const p = n.parent;
        // A shorthand property (`{ wait }`) reads the value of that name, so it is a reference to
        // the variable or function, resolved through the checker's own lookup for it.
        if (p && p.kind === SyntaxKind.ShorthandPropertyAssignment && p.name === n) {
          return [codePoint(file, n.getStart()), "short", target(project.checker.getShorthandAssignmentValueSymbol(p))];
        }
        const role = p && p.name === n && DECLARATIONS.has(p.kind) ? "decl"
          : p && (p.kind === SyntaxKind.CallExpression || p.kind === SyntaxKind.NewExpression) && p.expression === n ? "call"
          : "ref";
        return [codePoint(file, n.getStart()), role, target(symbols[i])];
      });
    }
  });
} finally {
  api.close();
  rmSync(dir, { recursive: true, force: true });
}
process.stdout.write(JSON.stringify(out));
