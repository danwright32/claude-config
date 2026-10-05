import type { ModKitChange, ModKitWrite, ModKitWrites } from '../types/index.d.ts'
import { git, pipeline, type Command } from './commands.ts'
import { kindOf } from './program.ts'

// The one reader of which files a Bash call changes (#705, L613), over the simple commands the
// shared reader gives. Ask before saving kept its own copy and missed inline scripts, rsync,
// install, ln, dd, a patch, every file but the last of a sed -i, and a relative path after a cd;
// the collision guard's copy (#654) already followed a cd and a copy into a folder, and its path,
// sed and perl readings are carried over here as they were reviewed there. No build's copy (#616)
// listed the copying commands, dd and inline scripts; curl and wget's output files, gawk's and
// ruby's in place editing were missing from all three (#702), and a file curl or wget saves under
// the address's own name from every reader (#726). The collision guard and no build moved onto it
// in #712, bringing what each read that it did not: a file removed (rm, rmdir, unlink, a mv's
// source, find -delete), stamped (touch), emptied (truncate, shred), made (mkdir) or changed in
// mode (chmod, chown, chgrp), reported apart from the files content goes into as `changes`.
//
// Inline code is judged by the reader's per language judge (code.ts), which each command already
// carries, and a shell fed its script is read as the commands it runs, so this keeps no list of
// interpreters or write idioms of its own. What it does not report: a script run from a file
// (python3 build.py), whose writes no word names and which are not guessed at (#654).

const WRITE_REDIRECT = /^(\d*>>?|\d*>\||&>>?)$/
const UNNAMEABLE = /[$`*?[\]{}]/
const HOME_VAR = /^\$(?:HOME|\{HOME\})(?=\/|$)/

const isDevice = (p: string) => p === '/dev' || p.startsWith('/dev/')

// A variable the command set before a write is read as its value, as the shell reads it, so the
// write names its file (#743: `F=<memory folder>/MEMORY.md; printf ... >> "$F"` was given as $F,
// with no path, and ask before saving let it through). The word is still given as written. Only a
// value the reader can be sure of: one holding a command's output or anything else it cannot name;
// one a loop, read, mapfile, getopts or printf -v sets, appended to or unset; one given a second,
// different value (the reader cannot tell a ; from an && or ||, so which stands is unknown); and
// every value once an eval or a sourced file may have changed it, is left as written. A value set
// inside a subshell ends with it.
const SETS = /^([A-Za-z_][A-Za-z0-9_]*)=([\s\S]*)$/
const APPENDS = /^([A-Za-z_][A-Za-z0-9_]*)\+=/
const NAME = /^[A-Za-z_][A-Za-z0-9_]*$/
const VARIABLE = /\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))/g
const DECLARES = new Set(['export', 'declare', 'typeset', 'local', 'readonly'])
const READS = new Set(['read', 'mapfile', 'readarray', 'getopts', 'unset'])
const LOOPS = new Set(['for', 'select'])
const RUNS_TEXT = new Set(['eval', 'source', '.'])
type Vars = Map<string, string | null>

/**
 * A word as an absolute path, or undefined when it cannot be named: built from a variable other
 * than HOME or a pattern, a ~user, or relative to a folder that is not known.
 */
export const absolutePath = (word: string, dir: string | undefined, home: string): string | undefined => {
  if (!word) return undefined
  let p = word
  const hv = HOME_VAR.exec(p)
  if (hv) {
    if (!home) return undefined
    p = home + p.slice(hv[0].length)
  }
  if (UNNAMEABLE.test(p)) return undefined
  if (p === '~' || p.startsWith('~/')) {
    if (!home) return undefined
    p = home + p.slice(1)
  } else if (p.startsWith('~')) return undefined
  if (!p.startsWith('/')) {
    if (!dir) return undefined
    p = `${dir}/${p}`
  }
  const parts: string[] = []
  for (const seg of p.split('/')) {
    if (seg === '' || seg === '.') continue
    if (seg === '..') parts.pop()
    else parts.push(seg)
  }
  return `/${parts.join('/')}`
}

const baseOf = (p: string) => p.split('/').filter(Boolean).pop() ?? p

// The operands of a command after its options, taking a value from the next word for the options
// named in `valued` (an option written --name=value carries its own). After -- everything is an
// operand.
const operands = (args: string[], valued: ReadonlySet<string>): { ops: string[]; opts: Map<string, string | true> } => {
  const ops: string[] = []
  const opts = new Map<string, string | true>()
  for (let i = 0; i < args.length; i++) {
    const a = args[i] as string
    if (a === '--') {
      ops.push(...args.slice(i + 1))
      break
    }
    if (a.startsWith('-') && a !== '-') {
      const eq = a.indexOf('=')
      if (a.startsWith('--') && eq > 0) opts.set(a.slice(0, eq), a.slice(eq + 1))
      else if (valued.has(a)) opts.set(a, args[++i] ?? '')
      else opts.set(a, true)
    } else ops.push(a)
  }
  return { ops, opts }
}

// sed's files when it edits them in place: -i, -i<suffix>, --in-place[=suffix], with BSD's -i ''
// or -i .bak taking the next word as the suffix. The script is the first operand unless -e or -f
// gave it.
type InPlace = { inPlace: boolean; files: string[] }
const sedInPlace = (args: string[]): InPlace => {
  let inPlace = false
  let scripted = false
  const ops: string[] = []
  for (let i = 0; i < args.length; i++) {
    const a = args[i] as string
    if (a === '-e' || a === '-f' || a === '--expression' || a === '--file') {
      scripted = true
      i++
    } else if (a.startsWith('--expression=') || a.startsWith('--file=')) scripted = true
    else if (a === '-i') {
      inPlace = true
      const next = args[i + 1]
      if (next !== undefined && (next === '' || next.startsWith('.'))) i++
    } else if (a === '--in-place' || a.startsWith('--in-place=') || /^-[a-zA-Z]*i/.test(a)) inPlace = true
    else if (a.startsWith('-') && a !== '-') continue
    else ops.push(a)
  }
  return { inPlace, files: !inPlace ? [] : scripted ? ops : ops.slice(1) }
}

// perl's (and ruby's) files when -i edits them in place. In a cluster such as -pi.bak or -pie, what
// follows the i is its suffix; a script letter (perl's e or E, ruby's e) takes the rest of the
// cluster, or the next word, as the script; a value letter takes the rest of the cluster as its value.
// A digits letter takes only the digits after it (perl's -0777 or -0x1F, -l015), so the letters
// after those are options again: -0pi and -lpi edit in place.
const PERL = { script: 'eE', valued: 'IMmxCdD', digits: '0l' }
const RUBY = { script: 'e', valued: 'IrCEFxWTK', digits: '0' }
const inPlaceCluster = (args: string[], letters: { script: string; valued: string; digits: string }): InPlace => {
  let inPlace = false
  let scripted = false
  const ops: string[] = []
  for (let i = 0; i < args.length; i++) {
    const a = args[i] as string
    if (a === '--') {
      ops.push(...args.slice(i + 1))
      break
    }
    if (!a.startsWith('-') || a === '-') {
      ops.push(a)
      continue
    }
    const cluster = a.slice(1)
    for (let j = 0; j < cluster.length; j++) {
      const l = cluster[j] as string
      if (l === 'i') {
        inPlace = true
        break
      }
      if (letters.script.includes(l)) {
        scripted = true
        if (j === cluster.length - 1) i++
        break
      }
      // The rest of the cluster is this letter's value (-Ilib, -MPOSIX), never more letters, so
      // the i in -Ilib is not -i.
      if (letters.valued.includes(l)) break
      if (letters.digits.includes(l)) {
        const value = /^(?:x[0-9a-fA-F]*|[0-7]*)/.exec(cluster.slice(j + 1))?.[0] ?? ''
        j += value.length
      }
    }
  }
  return { inPlace, files: !inPlace ? [] : scripted ? ops : ops.slice(1) }
}

// awk's files when gawk edits them in place (-i inplace, -iinplace, --include=inplace, the
// extension named with its .awk too): every operand after the program, which is the first operand
// unless -f, -e or --source gave it, and never a var=value operand, which is an assignment (no
// build's own reading, #714, carried over in #712).
const INPLACE = /^inplace(?:\.awk)?$/
const awkInPlace = (args: string[]): InPlace => {
  let inPlace = false
  let scripted = false
  const ops: string[] = []
  for (let i = 0; i < args.length; i++) {
    const a = args[i] as string
    const attached = /^(?:-i|--include=)(.+)$/.exec(a)
    if (attached) {
      if (INPLACE.test(attached[1] as string)) inPlace = true
    } else if (a === '-i' || a === '--include') {
      if (INPLACE.test(args[i + 1] ?? '')) inPlace = true
      i++
    } else if (['-f', '-e', '-E', '--file', '--source', '--exec'].includes(a)) {
      scripted = true
      i++
    } else if (['-v', '-F', '-l', '--assign', '--field-separator', '--load'].includes(a)) i++
    else if (a.startsWith('-') && a !== '-') continue
    else ops.push(a)
  }
  const files = (scripted ? ops : ops.slice(1)).filter(o => !/^[A-Za-z_][A-Za-z0-9_]*=/.test(o))
  return { inPlace, files: inPlace ? files : [] }
}

// What curl and wget save (#726): the files their options name, and a file saved under the
// address's own name, which a download into lasting memory by its remote name used to slip past.
// Each is read option by option in the order given: a short option alone (-o out), in a cluster
// (-sSLO, -sSo out) or with its value attached (-oout, -qO-), a long one with its value next or
// after = (--output out, --output=out); every other word is an address.
// `into` is the folder an unnamed download lands in, where the words name one.
type Download = { files: string[]; unnamed: { what: string; inputs: string[]; into?: string }[] }
type Grammar = { short: string; long: ReadonlySet<string> }
const options = (args: string[], g: Grammar, opt: (name: string, value: string | undefined) => void, address: (a: string) => void) => {
  for (let i = 0; i < args.length; i++) {
    const a = args[i] as string
    if (a === '--') {
      args.slice(i + 1).forEach(address)
      return
    }
    if (a.startsWith('--')) {
      const eq = a.indexOf('=')
      const name = eq > 0 ? a.slice(0, eq) : a
      opt(name, eq > 0 ? a.slice(eq + 1) : g.long.has(name) ? (args[++i] ?? '') : undefined)
    } else if (a.startsWith('-') && a !== '-') {
      for (let j = 1; j < a.length; j++) {
        const l = a[j] as string
        if (!g.short.includes(l)) {
          opt(l, undefined)
          continue
        }
        opt(l, j < a.length - 1 ? a.slice(j + 1) : (args[++i] ?? ''))
        break
      }
    } else address(a)
  }
}

// An address's path and query, its scheme, host and fragment taken off.
const addressParts = (url: string): { path: string; query: string } => {
  const whole = url.split('#')[0] as string
  const q = whole.indexOf('?')
  const rest = (q < 0 ? whole : whole.slice(0, q)).replace(/^[A-Za-z][A-Za-z0-9+.-]*:\/\//, '')
  const slash = rest.indexOf('/')
  return { path: slash < 0 ? '' : rest.slice(slash), query: q < 0 ? '' : whole.slice(q) }
}
const lastPart = (path: string) => path.slice(path.lastIndexOf('/') + 1)
const under = (dir: string | undefined, file: string) => (dir && !/^[/~$]/.test(file) ? `${dir.replace(/\/+$/, '')}/${file}` : file)

// curl's options that take a value (curl 8.7.1's --help all), so a value is never taken for an
// address. Each -o or -O is for the next address in turn; one left over goes to standard output
// unless --remote-name-all. A remote name is the address's last part, query and fragment off (as
// curl 8.7 saves it, measured 2026-10-04); an address with none saves nothing.
const CURL: Grammar = {
  short: 'EKCbcdDFPHhmoUQreXYytzTuAwx',
  long: new Set(['--cert', '--config', '--continue-at', '--cookie', '--cookie-jar', '--data', '--dump-header', '--form', '--ftp-port', '--header', '--help', '--max-time', '--output', '--proxy-user', '--quote', '--range', '--referer', '--request', '--speed-limit', '--speed-time', '--telnet-option', '--time-cond', '--upload-file', '--user', '--user-agent', '--write-out', '--proxy', '--preproxy', '--abstract-unix-socket', '--alt-svc', '--aws-sigv4', '--cacert', '--capath', '--cert-type', '--ciphers', '--connect-timeout', '--connect-to', '--create-file-mode', '--crlfile', '--curves', '--data-ascii', '--data-binary', '--data-raw', '--data-urlencode', '--delegation', '--dns-interface', '--dns-ipv4-addr', '--dns-ipv6-addr', '--dns-servers', '--doh-url', '--egd-file', '--engine', '--etag-compare', '--etag-save', '--expect100-timeout', '--form-string', '--ftp-account', '--ftp-alternative-to-user', '--ftp-method', '--ftp-ssl-ccc-mode', '--happy-eyeballs-timeout-ms', '--haproxy-clientip', '--hostpubmd5', '--hostpubsha256', '--hsts', '--interface', '--ipfs-gateway', '--json', '--keepalive-time', '--key', '--key-type', '--krb', '--libcurl', '--limit-rate', '--local-port', '--login-options', '--mail-auth', '--mail-from', '--mail-rcpt', '--max-filesize', '--max-redirs', '--netrc-file', '--noproxy', '--oauth2-bearer', '--output-dir', '--parallel-max', '--pass', '--pinnedpubkey', '--proto', '--proto-default', '--proto-redir', '--proxy-cacert', '--proxy-capath', '--proxy-cert', '--proxy-cert-type', '--proxy-ciphers', '--proxy-crlfile', '--proxy-header', '--proxy-key', '--proxy-key-type', '--proxy-pass', '--proxy-pinnedpubkey', '--proxy-service-name', '--proxy-tls13-ciphers', '--proxy-tlsauthtype', '--proxy-tlspassword', '--proxy-tlsuser', '--pubkey', '--random-file', '--rate', '--request-target', '--resolve', '--retry', '--retry-delay', '--retry-max-time', '--sasl-authzid', '--service-name', '--socks4', '--socks4a', '--socks5', '--socks5-gssapi-service', '--socks5-hostname', '--stderr', '--tftp-blksize', '--tls-max', '--tls13-ciphers', '--tlsauthtype', '--tlspassword', '--tlsuser', '--trace', '--trace-ascii', '--trace-config', '--unix-socket', '--url', '--url-query', '--variable']),
}
// The files curl writes beside its output, each named by its value ('-' is standard output).
const CURL_FILES = new Set(['c', '--cookie-jar', 'D', '--dump-header', '--trace', '--trace-ascii', '--etag-save', '--stderr', '--libcurl'])
const curlDownload = (args: string[]): Download => {
  const outputs: (string | null)[] = []
  const urls: string[] = []
  const files: string[] = []
  let all = false
  let serverNames = false
  let dir: string | undefined
  options(
    args,
    CURL,
    (name, value) => {
      if (name === 'O' || name === '--remote-name') outputs.push(null)
      else if (name === 'o' || name === '--output') outputs.push(value ?? '')
      else if (name === '--remote-name-all') all = true
      else if (name === 'J' || name === '--remote-header-name') serverNames = true
      else if (name === '--output-dir') dir = value
      else if (name === '--url' && value) urls.push(value)
      else if (CURL_FILES.has(name) && value && value !== '-') files.push(value)
    },
    a => urls.push(a),
  )
  let remote = false
  urls.forEach((url, n) => {
    const out = n < outputs.length ? outputs[n] : all ? null : undefined
    if (out === undefined) return
    if (out !== null) {
      if (out && out !== '-') files.push(under(dir, out))
      return
    }
    remote = true
    const name = lastPart(addressParts(url).path)
    if (name) files.push(under(dir, name))
  })
  return { files, unnamed: serverNames && remote ? [{ what: 'a curl download the server names', inputs: [], ...(dir ? { into: dir } : {}) }] : [] }
}

// wget's options that take a value (GNU wget 1.21's --help). A plain wget saves each address under
// its last part with its query (GNU wget keeps it), index.html for a folder, into the current
// folder or -P's. -O puts everything in its one file. Recursive and mirrored downloads, names the
// server gives and addresses read from a file are writes the words do not name. --spider only
// checks each address and saves nothing (no build's own reading, carried over in #712).
const WGET: Grammar = {
  short: 'oaiBetOTwQPlARDIXU',
  long: new Set(['--output-file', '--append-output', '--execute', '--config', '--input-file', '--base', '--bind-address', '--bind-dns-address', '--dns-servers', '--tries', '--output-document', '--backups', '--timeout', '--dns-timeout', '--connect-timeout', '--read-timeout', '--wait', '--waitretry', '--quota', '--limit-rate', '--prefer-family', '--user', '--password', '--local-encoding', '--remote-encoding', '--directory-prefix', '--cut-dirs', '--default-page', '--http-user', '--http-password', '--header', '--compression', '--max-redirect', '--proxy-user', '--proxy-password', '--referer', '--save-cookies', '--load-cookies', '--post-data', '--post-file', '--method', '--body-data', '--body-file', '--user-agent', '--secure-protocol', '--certificate', '--certificate-type', '--private-key', '--private-key-type', '--ca-certificate', '--ca-directory', '--crl-file', '--pinnedpubkey', '--random-file', '--egd-file', '--ciphers', '--hsts-file', '--warc-file', '--warc-header', '--warc-max-size', '--warc-tempdir', '--ftp-user', '--ftp-password', '--level', '--accept', '--reject', '--accept-regex', '--reject-regex', '--regex-type', '--domains', '--exclude-domains', '--follow-tags', '--ignore-tags', '--include-directories', '--exclude-directories', '--restrict-file-names', '--progress', '--report-speed', '--use-askpass']),
}
const WGET_FILES = new Set(['o', '--output-file', 'a', '--append-output', '--save-cookies'])
const WGET_MANY = new Set(['r', '--recursive', 'm', '--mirror', 'p', '--page-requisites', 'x', '--force-directories'])
const wgetDownload = (args: string[]): Download => {
  const urls: string[] = []
  const files: string[] = []
  const lists: string[] = []
  let document: string | undefined
  let prefix: string | undefined
  let many = false
  let serverNames = false
  let spider = false
  // wget's -nd, -nH, -np, -nc and -nv are two letters each, never a cluster.
  options(
    args.filter(a => !/^-n[A-Za-z]+$/.test(a)),
    WGET,
    (name, value) => {
      if (name === 'O' || name === '--output-document') document = value
      else if (name === 'P' || name === '--directory-prefix') prefix = value
      else if (name === 'i' || name === '--input-file') lists.push(value ?? '')
      else if (name === '--content-disposition') serverNames = true
      else if (name === '--spider') spider = true
      else if (WGET_MANY.has(name)) many = true
      else if (WGET_FILES.has(name) && value && value !== '-') files.push(value)
    },
    a => urls.push(a),
  )
  const unnamed: Download['unnamed'] = []
  const into = prefix ? { into: prefix } : {}
  if (spider) return { files, unnamed }
  if (lists.length) unnamed.push({ what: 'a wget download of the addresses in a file', inputs: lists.filter(l => l && l !== '-'), ...into })
  if (document !== undefined) {
    if (document && document !== '-') files.push(document)
  } else if (many) unnamed.push({ what: 'a wget download of many files', inputs: [], ...into })
  else {
    for (const url of urls) {
      const { path, query } = addressParts(url)
      files.push(under(prefix, `${lastPart(path) || 'index.html'}${query}`))
    }
    if (serverNames && urls.length) unnamed.push({ what: 'a wget download the server names', inputs: [], ...into })
  }
  return { files, unnamed }
}

// The options that take a value, per command whose destination is its last operand, so a value is
// never taken for the destination (install -m 644, rsync --exclude .git, ditto --arch arm64).
const VALUED: Record<string, ReadonlySet<string>> = {
  cp: new Set(['-t', '-S', '--target-directory', '--suffix']),
  mv: new Set(['-t', '-S', '--target-directory', '--suffix']),
  ln: new Set(['-t', '-S', '--target-directory', '--suffix']),
  install: new Set(['-t', '-m', '-o', '-g', '-S', '-B', '-f', '-M', '--target-directory', '--mode', '--owner', '--group', '--suffix']),
  ditto: new Set(['--arch', '--bom']),
  rsync: new Set(['-e', '-f', '-T', '-B', '--rsh', '--exclude', '--include', '--filter', '--files-from', '--exclude-from', '--include-from', '--chmod', '--log-file', '--rsync-path', '--port', '--temp-dir', '--backup-dir', '--suffix', '--compare-dest', '--link-dest', '--copy-dest', '--block-size', '--bwlimit', '--timeout', '--max-size', '--min-size', '--partial-dir']),
}

// A destination on another machine (host:path, user@host:path) is no file here.
const isRemote = (w: string) => /^[^/]*:/.test(w) && !w.startsWith('/')

// Input words: `<` and the file after it, `<file`, a heredoc's `<<EOF` (or `<<` and its delimiter
// as the next word, #698), a here-string's `<<<` and its text, each with any descriptor number
// before it. Taken out of a command's words, so its operands are what is left.
const splitInputs = (words: string[]): { rest: string[]; files: string[] } => {
  const rest: string[] = []
  const files: string[] = []
  for (let i = 0; i < words.length; i++) {
    const w = words[i] as string
    if (/^\d*<<<$/.test(w)) i++
    else if (/^\d*<<</.test(w)) continue
    else if (/^\d*<</.test(w)) {
      if (/^\d*<<-?$/.test(w)) i++
    } else if (/^\d*<$/.test(w)) {
      if (words[i + 1] !== undefined) files.push(words[++i] as string)
    } else if (/^\d*</.test(w) && !w.startsWith('<(')) files.push(w.replace(/^\d*</, ''))
    else rest.push(w)
  }
  return { rest, files }
}

// The commands that change files by their operands, so one xargs gives its operands to changes
// files no word names (#730). An editor that edits in place only with its flag is told apart where
// it is read.
const OPERAND_WRITERS = new Set(['tee', 'cp', 'mv', 'ln', 'install', 'ditto', 'rsync', 'rm', 'unlink', 'rmdir', 'touch', 'mkdir', 'truncate', 'shred', 'chmod', 'chown', 'chgrp', 'patch'])
// Each changer's options that take the next word as a value, so a value is never taken for a file.
const CHANGERS: Record<string, { does: ModKitChange['does']; valued: ReadonlySet<string> }> = {
  rm: { does: 'remove', valued: new Set() },
  unlink: { does: 'remove', valued: new Set() },
  rmdir: { does: 'remove', valued: new Set() },
  touch: { does: 'touch', valued: new Set(['-t', '-r', '-d', '-A', '--reference', '--date']) },
  mkdir: { does: 'folder', valued: new Set(['-m', '--mode']) },
  truncate: { does: 'truncate', valued: new Set(['-s', '-r', '--size', '--reference']) },
  shred: { does: 'truncate', valued: new Set(['-n', '-s', '--iterations', '--size', '--random-source']) },
  chmod: { does: 'mode', valued: new Set() },
  chown: { does: 'mode', valued: new Set() },
  chgrp: { does: 'mode', valued: new Set() },
}
const FIND_FILE_ACTIONS = new Set(['-fprint', '-fprint0', '-fprintf', '-fls'])

/**
 * The files a Bash call changes, read from the reader's commands (`pipeline`, with the assignments it
 * otherwise drops: `commandWrites`): the files it puts content into, each as written and as an
 * absolute path where its words name one (home spelled out, a cd before it followed, a variable the
 * command set read as its value), with a copy's sources and an in place edit marked; the other
 * changes it makes to files (removed, stamped, emptied, made, a mode changed), a removal or mode
 * change of a whole folder marked as its tree; and the writes whose files its words do not name (a
 * patch, a program that writes or runs a process or cannot be read, a script on standard input, a
 * command xargs gives its files), each with the files to read to find out, such as the patch.
 */
export const writes = (cmds: readonly Command[], cwd: string, home: string): ModKitWrites => {
  const files: ModKitWrite[] = []
  const changes: ModKitChange[] = []
  const unnamed: ModKitWrites['unnamed'] = []
  const seen = new Set<string>()
  let dir: string | undefined = cwd
  let vars: Vars = new Map()
  // Each word of the command being read that a variable's value replaced, as it was written.
  const asWritten = new Map<string, string>()
  const add = (word: string, path: string | undefined, extra?: { sources?: string[]; edits?: true; mayBeFolder?: true }) => {
    if (!word || isDevice(path ?? word)) return
    const key = path ?? `word:${word}`
    if (seen.has(key)) return
    seen.add(key)
    const sources = extra?.sources
    files.push({
      word: asWritten.get(word) ?? word,
      ...(path ? { path } : {}),
      ...(sources && sources.length ? { sources } : {}),
      ...(extra?.edits ? { edits: true as const } : {}),
      ...(extra?.mayBeFolder ? { mayBeFolder: true as const } : {}),
    })
  }
  const named = (w: string, edits?: true) => add(w, absolutePath(w, dir, home), edits ? { edits } : undefined)
  const changed = (word: string, does: ModKitChange['does'], tree?: boolean) => {
    const path = absolutePath(word, dir, home)
    if (!word || isDevice(path ?? word)) return
    const written = asWritten.get(word) ?? word
    // A path changed the same way twice is kept once, a tree on either keeping the tree.
    const had = changes.find(x => x.does === does && (path ? x.path === path : !x.path && x.word === written))
    if (had) {
      if (tree) had.tree = true
      return
    }
    changes.push({ word: written, ...(path ? { path } : {}), does, ...(tree ? { tree: true as const } : {}) })
  }
  const abs = (p: string) => absolutePath(p, dir, home)
  const absAll = (ps: string[]) => ps.map(abs).filter((p): p is string => !!p)
  const expand = (w: string) => w.replace(VARIABLE, (m, braced?: string, bare?: string) => vars.get((braced ?? bare) as string) ?? m)
  const unknown = (name: string) => vars.set(name, null)
  const assign = (word: string) => {
    const m = SETS.exec(word)
    if (!m) return
    const name = m[1] as string
    // Home is spelled out where a value starts with it, as the shell expands ~ in an assignment.
    let value = expand(m[2] as string)
    if (home) value = value.replace(HOME_VAR, home).replace(/^~(?=\/|$)/, home)
    const known = /[$`()]/.test(value) ? null : value
    vars.set(name, vars.has(name) && vars.get(name) !== known ? null : known)
  }
  // The folder outside each subshell still open: the reader gives its parentheses as commands of
  // their own (#700), and a cd inside one ends with it. A closing one with no opening leaves the
  // folder as it is. The variables outside it are kept the same way.
  const outside: (string | undefined)[] = []
  const varsOutside: Vars[] = []
  for (const c of cmds) {
    const written = c.words
    if (written.length === 1 && written[0] === '(') {
      outside.push(dir)
      varsOutside.push(new Map(vars))
      continue
    }
    if (written[0] === ')') {
      if (outside.length) dir = outside.pop()
      if (varsOutside.length) vars = varsOutside.pop() as Vars
    }
    if (written.length && written.every(w => SETS.test(w))) {
      written.forEach(assign)
      continue
    }
    asWritten.clear()
    const raw = written.map(expand)
    raw.forEach((w, n) => {
      if (w !== written[n]) asWritten.set(w, written[n] as string)
    })
    // Output redirects first, and taken out of the words, with descriptor copies (2>&1). A `>&`
    // with nothing attached takes the next word: a number or - is a descriptor copied, anything
    // else a file both outputs go to (the collision guard's reading, #654, kept in #712).
    const words: string[] = []
    for (let i = 0; i < raw.length; i++) {
      const w = raw[i] as string
      if (WRITE_REDIRECT.test(w)) {
        const target = raw[++i]
        if (target !== undefined) named(target)
      } else if (/^\d*>&$/.test(w)) {
        const target = raw[++i]
        if (target !== undefined && !/^(?:\d+|-)$/.test(target)) named(target)
      } else if (/^\d*>&[0-9-]*$/.test(w)) continue
      else words.push(w)
    }
    if (raw[0] === ')') continue
    const { rest: args, files: inputs } = splitInputs(words)
    const name = baseOf(args[0] ?? '')
    const kind = kindOf(args[0])
    const rest = args.slice(1)
    if (DECLARES.has(name)) {
      // export F=path, declare -x F=path. Any option beyond export, read only and global (an array,
      // a name reference, a case change) gives a value the reader cannot read.
      const plain = rest.every(a => !a.startsWith('-') || /^-[xrg]+$/.test(a))
      for (const a of rest) {
        const m = SETS.exec(a)
        if (m && plain) assign(a)
        else if (m) unknown(m[1] as string)
      }
      continue
    }
    const appended = APPENDS.exec(args[0] ?? '')
    if (appended) {
      unknown(appended[1] as string)
      continue
    }
    if (READS.has(name)) {
      for (const a of rest) if (NAME.test(a)) unknown(a)
      continue
    }
    if (LOOPS.has(name)) {
      if (rest[0] !== undefined) unknown(rest[0])
      continue
    }
    if (RUNS_TEXT.has(name)) for (const k of vars.keys()) unknown(k)
    const v = name === 'printf' ? rest.indexOf('-v') : -1
    if (v >= 0 && rest[v + 1] !== undefined) unknown(rest[v + 1] as string)
    // Whether this command changes files given as operands, for one xargs runs.
    let writer = OPERAND_WRITERS.has(name)
    if (name === 'cd' || name === 'pushd') {
      const target = rest.find(a => !a.startsWith('-') || a === '-')
      dir = target === undefined ? home || undefined : target === '-' ? undefined : absolutePath(target, dir, home)
      continue
    }
    if (name === 'tee') for (const f of operands(rest, new Set()).ops) named(f)
    else if (kind === 'sed') {
      const e = sedInPlace(rest)
      writer = e.inPlace
      for (const f of e.files) named(f, true)
    } else if ((kind === 'perl' || kind === 'ruby') && inPlaceCluster(rest, kind === 'perl' ? PERL : RUBY).inPlace) {
      writer = true
      for (const f of inPlaceCluster(rest, kind === 'perl' ? PERL : RUBY).files) named(f, true)
    } else if (kind === 'awk') {
      const e = awkInPlace(rest)
      writer = e.inPlace
      for (const f of e.files) named(f, true)
    } else if (name === 'dd') {
      for (const a of rest) if (a.startsWith('of=')) named(a.slice(3))
    } else if (name === 'curl' || name === 'wget') {
      const got = name === 'curl' ? curlDownload(rest) : wgetDownload(rest)
      for (const f of got.files) named(f)
      for (const u of got.unnamed) {
        const into = u.into === undefined ? undefined : abs(u.into)
        unnamed.push({ what: u.what, words: raw, inputs: absAll(u.inputs), ...(into ? { into } : {}) })
      }
    } else if (VALUED[name]) {
      const { ops, opts } = operands(rest, VALUED[name] as ReadonlySet<string>)
      const intoOpt = opts.get('-t') ?? opts.get('--target-directory')
      let into: string | undefined
      let sources = ops
      let copied = true
      if (typeof intoOpt === 'string') into = intoOpt
      else {
        const dest = ops[ops.length - 1]
        sources = ops.slice(0, -1)
        if (dest === undefined || sources.length === 0 || isRemote(dest)) copied = false
        // rsync copies a folder's contents for a source ending in /, so only the folder is known.
        else if ((sources.length > 1 || dest.endsWith('/')) && !(name === 'rsync' && sources.some(s => s.endsWith('/')))) into = dest
        // One source onto one name lands inside it when that is an existing folder, which only the
        // disk can say (the collision guard's reading, #654), so the write says so.
        else add(dest, abs(dest), { sources: absAll(sources), mayBeFolder: true })
      }
      if (copied && into !== undefined) {
        const intoPath = abs(into)
        for (const s of sources) add(`${into.replace(/\/+$/, '')}/${baseOf(s)}`, intoPath ? `${intoPath}/${baseOf(s)}` : undefined, { sources: absAll([s]) })
      }
      // mv takes each source away whole: a folder with everything under it, as rm -r does (the
      // collision guard's reading, lessons review of #691).
      if (name === 'mv' && copied) for (const s of sources) changed(s, 'remove', true)
    } else if (CHANGERS[name]) {
      const ch = CHANGERS[name] as { does: ModKitChange['does']; valued: ReadonlySet<string> }
      const { ops, opts } = operands(rest, ch.valued)
      const flags = [...opts.keys()]
      // rm -r, -R or --recursive in any cluster, and chmod, chown or chgrp -R, reach a whole tree.
      const recursive = (name === 'rm' && flags.some(k => k === '--recursive' || /^-[A-Za-z]*[rR]/.test(k))) || (ch.does === 'mode' && flags.some(k => k === '--recursive' || /^-[A-Za-z]*R/.test(k)))
      // chmod, chown and chgrp take the mode or owner first, unless --reference names a file for it
      // or chmod's mode was written as a flag (chmod -x run.sh).
      const modeGiven = flags.some(k => k === '--reference') || (name === 'chmod' && flags.some(k => /^-[rwxXst]+$/.test(k)))
      const targets = ch.does === 'mode' && !modeGiven ? ops.slice(1) : ops
      for (const f of targets) changed(f, ch.does, recursive)
      if (name === 'shred' && flags.some(k => k === '-u' || k === '--remove' || /^-[A-Za-z]*u/.test(k))) for (const f of targets) changed(f, 'remove')
    } else if (name === 'find') {
      // find -delete removes what it finds under each folder it starts from, and -fprint and its
      // kin write a file (no build's reading, #714, carried over in #712). What -exec runs comes
      // after it as a command of its own.
      const firstExpr = rest.findIndex(a => a.startsWith('-') || a === '(' || a === '!')
      const roots = firstExpr < 0 ? rest : rest.slice(0, firstExpr)
      for (let i = 0; i < rest.length; i++) {
        const a = rest[i] as string
        if (a === '-delete') for (const r of roots.length ? roots : ['.']) changed(r, 'remove', true)
        else if (FIND_FILE_ACTIONS.has(a) && rest[i + 1] !== undefined) named(rest[++i] as string)
        else if (['-exec', '-execdir', '-ok', '-okdir'].includes(a)) {
          const end = rest.findIndex((w, j) => j > i && (w === ';' || w === '+'))
          i = end < 0 ? rest.length : end
        }
      }
    } else if (name === 'patch') {
      const { ops, opts } = operands(rest, new Set(['-i', '-p', '-d', '-o', '-r', '-B', '-D', '-F', '-V', '-z', '--input', '--directory', '--output']))
      // patch [file to patch [patch file]]: the first operand is written, as named.
      if (ops[0] !== undefined) named(ops[0])
      const patches = [opts.get('-i'), opts.get('--input'), ops[1], ...inputs].filter((p): p is string => typeof p === 'string' && p !== '')
      unnamed.push({ what: 'a patch', words: raw, inputs: absAll(patches) })
    } else {
      const g = git(args)
      if (g && (g.sub === 'apply' || g.sub === 'am')) {
        // Checked or summarised, a patch writes nothing.
        if (!g.args.some(a => ['--check', '--stat', '--numstat', '--summary'].includes(a))) {
          const at = g.dir === undefined ? dir : absolutePath(g.dir, dir, home)
          const patches = [...operands(g.args, new Set(['-p', '-C', '--directory', '--exclude', '--include'])).ops, ...inputs]
          unnamed.push({ what: 'a patch', words: raw, inputs: patches.map(p => absolutePath(p, at, home)).filter((p): p is string => !!p) })
        }
      }
    }
    // A program the reader read (code.ts judged it): one that writes, runs a process or cannot be
    // read is a write the words do not name, and so is one that cannot be read at all (a script
    // piped in from curl). A shell reaches here only when its script could not be read, since the
    // reader gives one it could read as the commands it runs. A script file named as an operand is
    // not guessed at (#654); one fed on standard input names the file to read.
    const p = c.program
    const onStdin = `a ${name} script on standard input`
    if (c.script && !c.script.stdin) {
      // A script file named as an operand, or a program file (awk -f), is not guessed at.
    } else if (p && 'unreadable' in p) unnamed.push({ what: onStdin, words: raw, inputs: [] })
    else if (c.verdict) unnamed.push({ what: p && 'text' in p && p.stdin ? onStdin : `an inline ${name} script`, words: raw, inputs: [] })
    else if (c.script?.stdin) unnamed.push({ what: onStdin, words: raw, inputs: absAll(c.script.files), script: true })
    // A command given its operands by xargs changes files no word names (#730).
    if (c.xargs && writer) unnamed.push({ what: `${name} given its files by xargs`, words: raw, inputs: [] })
  }
  return { files, changes, unnamed }
}

/** What a Bash call changes, read from its text: `$.modkit.writes`, and what its tests read. */
export const commandWrites = (command: string, cwd: string, home: string): ModKitWrites => writes(pipeline(command, { assignments: true }), cwd, home)
