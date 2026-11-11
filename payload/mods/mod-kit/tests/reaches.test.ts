import { expect } from 'claude-code/testing'
import { test } from './hang-ceiling.ts'
import { fileReach } from '../hooks/reaches.ts'

// The one reader of what a FILE's text reaches beyond itself (#2710): a program it starts, a web
// request it makes, or a module it loads by a name given at run time, counted only where the file
// imports or calls one. The Slack alert guard reads each file it searches with it, from a byte for
// byte copy at hooks/mod-kit/reaches.ts, in place of its own lists of module names.

const py = (text: string) => fileReach('python', text)
const node = (text: string) => fileReach('node', text)

test('a python file reaches out by what it imports or calls', () => {
  expect(py('import subprocess\n')).toEqual({ does: 'run a process', seen: 'subprocess' })
  expect(py('import os, subprocess\n')).toEqual({ does: 'run a process', seen: 'subprocess' })
  expect(py('import pty as p\n')).toEqual({ does: 'run a process', seen: 'pty' })
  expect(py('from multiprocessing import Pool\n')).toEqual({ does: 'run a process', seen: 'multiprocessing' })
  expect(py('os.system(cmd)\n')).toEqual({ does: 'run a process', seen: 'os.system' })
  expect(py('os.execvp(p, a)\n')).toEqual({ does: 'run a process', seen: 'os.execvp' })
  expect(py('from requests import post\n')).toEqual({ does: 'make a web request', seen: 'requests' })
  expect(py('import urllib.request\n')).toEqual({ does: 'make a web request', seen: 'urllib' })
  expect(py('import http.client as h\n')).toEqual({ does: 'make a web request', seen: 'http' })
  expect(py('from http.client import HTTPSConnection\n')).toEqual({ does: 'make a web request', seen: 'http' })
  // Slack's own client modules call its web API.
  expect(py('import slack_bolt_helpers\n')).toEqual({ does: 'make a web request', seen: 'slack_bolt_helpers' })
  expect(py('page = urlopen(u)\n')).toEqual({ does: 'make a web request', seen: 'urlopen' })
  expect(py('mod = __import__(name)\n')).toEqual({ does: 'load a module by name', seen: '__import__' })
  expect(py('mod = importlib.import_module(name)\n')).toEqual({ does: 'load a module by name', seen: 'import_module' })
  // A call inside an f-string's braces is code.
  expect(py('print(f"ran {os.system(cmd)}")\n')).toEqual({ does: 'run a process', seen: 'os.system' })
})

test('a python file that only NAMES a program or a module, in a string, a pattern or a comment, reaches nothing', () => {
  expect(py('import re, json\nprint("ok")\n')).toBeUndefined()
  // The Slack drafts gate's case (#2689): pty and subprocess as alternatives of a pattern it refuses.
  expect(py('import re\nRUNS = re.compile(r"\\b(subprocess|pty|os\\.system)\\b")\n')).toBeUndefined()
  expect(py("SENDERS = 'urllib|requests|pty|subprocess'\n")).toBeUndefined()
  expect(py('HELP = "run: import subprocess, then os.system(cmd)"\n')).toBeUndefined()
  expect(py('"""\nimport subprocess\nfrom requests import post\n"""\nx = 1\n')).toBeUndefined()
  expect(py("# import subprocess\nx = 1\n")).toBeUndefined()
  expect(py('print(f"import subprocess {name}")\n')).toBeUndefined()
  // A name that only starts like a module is another module.
  expect(py('import requests_cache_free_name\n')).toBeUndefined()
})

test('a JavaScript or TypeScript file reaches out by what it imports or calls', () => {
  expect(node("const { execFile } = require('node:child_process')\n")).toEqual({ does: 'run a process', seen: 'child_process' })
  expect(node("import { spawn } from 'child_process'\n")).toEqual({ does: 'run a process', seen: 'child_process' })
  expect(node("import { Worker } from 'worker_threads'\n")).toEqual({ does: 'run a process', seen: 'worker_threads' })
  expect(node("await Bun.spawn(['curl', u])\n")).toEqual({ does: 'run a process', seen: 'Bun.spawn' })
  expect(node("await $.process.run(['curl', u])\n")).toEqual({ does: 'run a process', seen: 'process.run' })
  expect(node('await $`curl ${u}`\n')).toEqual({ does: 'run a process', seen: '$`' })
  expect(node("import axios from 'axios'\n")).toEqual({ does: 'make a web request', seen: 'axios' })
  expect(node("const h = await import('https')\n")).toEqual({ does: 'make a web request', seen: 'https' })
  expect(node("import 'node:http/promises'\n")).toEqual({ does: 'make a web request', seen: 'http' })
  expect(node('export const go = (u: string) => fetch(u, { method: "POST" })\n')).toEqual({ does: 'make a web request', seen: 'fetch' })
  expect(node('const r = await got.post(u)\n')).toEqual({ does: 'make a web request', seen: 'got.post' })
  expect(node('const ws = new WebSocket(u)\n')).toEqual({ does: 'make a web request', seen: 'WebSocket' })
  expect(node('const c = await Deno.connect({ port })\n')).toEqual({ does: 'make a web request', seen: 'Deno.connect' })
  // Code inside a template literal's ${...} is code.
  expect(node('const s = `sent ${await fetch(u)}`\n')).toEqual({ does: 'make a web request', seen: 'fetch' })
})

test('a JavaScript or TypeScript file that only NAMES a program or a module reaches nothing', () => {
  expect(node("import { readFileSync } from 'node:fs'\nexport const x = 1\n")).toBeUndefined()
  expect(node("const RUNS = /\\b(child_process|fetch\\(|new WebSocket)/\n")).toBeUndefined()
  expect(node("const REFUSED = new RegExp('child_process|axios|fetch\\\\(', 'i')\n")).toBeUndefined()
  expect(node("const HINT = 'call fetch(url) or require(\"child_process\") yourself'\n")).toBeUndefined()
  expect(node('const t = `import axios from "axios"; fetch(u)`\n')).toBeUndefined()
  expect(node("// const { exec } = require('child_process')\n/* fetch(u) */\nexport const x = 1\n")).toBeUndefined()
})

test('a JavaScript division is not read as a pattern that hides the code after it, nor a quote in a pattern as a string', () => {
  expect(node('const half = total / count\nfetch(u)\n')).toEqual({ does: 'make a web request', seen: 'fetch' })
  // Read as a pattern, the first slash would run to the second and empty the call between them.
  expect(node('const r = a / b + (await fetch(u)).length / 2\n')).toEqual({ does: 'make a web request', seen: 'fetch' })
  expect(node("const q = /['\"]/\nfetch(u)\n")).toEqual({ does: 'make a web request', seen: 'fetch' })
  expect(node("const q = /[/']/g.test(x) ? 1 : 2\nfetch(u)\n")).toEqual({ does: 'make a web request', seen: 'fetch' })
})

test('code another program holds as text (a shell script\'s inline python or node) is read whole, its strings included', () => {
  const line = `python3 -c "import urllib.request; urllib.request.urlopen('$1')"\n`
  expect(fileReach('python', line)).toBeUndefined()
  expect(fileReach('python', line, { whole: true })).toEqual({ does: 'make a web request', seen: 'urllib' })
  expect(fileReach('node', 'node -e "fetch(process.argv[1])" "$1"\n', { whole: true })).toEqual({ does: 'make a web request', seen: 'fetch' })
})
