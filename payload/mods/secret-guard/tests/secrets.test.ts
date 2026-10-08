import { describe, expect, test } from 'claude-code/testing'
import {
  blockedCommand,
  commandRefusal,
  findKnownSecret,
  isEnvFile,
  scrub,
  secretsFromEnvText,
  secretsFromEnvList,
} from '../hooks/secrets.ts'
import { commands } from './mod-kit/hooks/commands.ts'

// Fixture values built at run time so this file holds no literal token shape of its own.
const GH = 'ghp_' + 'A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8'
const KNOWN = 'kN0wn-S3cr3t-v4lue-zz'

// blockedCommand judges what mod-kit's shared reader made of a command: each simple command as its
// words, quotes removed, sudo and env looked past, bash -c read as what it runs. How a command is
// READ is tested once, in mod-kit (L613); these are the guard's own decisions on what it reads.
const words = (s: string) => [s.split(' ')]

describe('blocked commands', () => {
  const blocked: [string, string[][], string][] = [
    ['cat .env', words('cat .env'), 'cat .env'],
    ['cat a project .env.local by path', words('cat apps/web/.env.local'), ''],
    ['head of .env', words('head -5 .env'), ''],
    ['cat of .env at a full path', words('/bin/cat .env'), ''],
    ['echo a token variable', words('echo $GITHUB_TOKEN'), ''],
    ['echo a braced key variable', [['echo', '${OPENAI_API_KEY}']], ''],
    ['printf a secret', [['printf', '%s', '$DB_PASSWORD']], ''],
    ['bare printenv', [['printenv']], ''],
    ['printenv a secret by name', words('printenv SLACK_TOKEN'), ''],
    ['bare env', [['env']], ''],
    ['gh auth token printed', words('gh auth token'), 'gh auth token'],
    ['gh auth token echoed through a substitution', [['echo', '$(gh', 'auth', 'token)']], 'echo $(gh auth token)'],
    ['a secret command after a harmless one', [['ls'], ['cat', '.env']], ''],
    ['grep over a .env file (lessons review)', words('grep . .env'), ''],
    ['awk over a .env file', [['awk', '{print}', '.env.local']], ''],
    ['jq over a .env file', words('jq . .env'), ''],
    ['grep with -e over a .env file', words('grep -e TOKEN .env'), ''],
  ]
  for (const [name, cmds, raw] of blocked) {
    test(`refuses ${name}`, () => {
      expect(blockedCommand(cmds, raw)).toBeDefined()
    })
  }

  const allowed: [string, string[][], string][] = [
    ['a presence check', [['[', '-n', '$GITHUB_TOKEN', ']'], ['echo', 'set']], ''],
    ['the length of a secret', words('echo ${#GITHUB_TOKEN}'), ''],
    ['printenv of an ordinary variable', words('printenv PATH'), ''],
    ['an env that runs a command, as the reader hands it over', words('make build'), 'env FOO=1 make build'],
    ['gh auth token captured into a variable', words('gh pr list'), 'GH_TOKEN=$(gh auth token -u danwright32) gh pr list'],
    ['gh auth status', words('gh auth status'), 'gh auth status'],
    ['cat of an example env file', words('cat .env.example'), ''],
    ['echo of an ordinary variable', words('echo $HOME'), ''],
    ['echo of a name that only contains KEY', words('echo $KEYBOARD_LAYOUT'), ''],
    ['printenv of a name that only contains TOKEN', words('printenv TOKENIZER_DIR'), ''],
    ['cat of an unrelated file', words('cat README.md'), ''],
    // The first plain argument of a filter tool is its program or pattern, not a file: a jq filter
    // reading .env.X out of settings.json was refused live on 2026-10-03.
    ['a jq filter that starts with .env.', [['jq', '-r', '.env.CLAUDE_CODE_PLUGIN_DIRS', '/Users/x/.claude/settings.json']], ''],
    ['a grep for the text .env', words('grep -n .env notes.txt'), ''],
    ['an awk program naming .env', [['awk', '/.env/ {print}', 'notes.txt']], ''],
  ]
  for (const [name, cmds, raw] of allowed) {
    test(`allows ${name}`, () => {
      expect(blockedCommand(cmds, raw)).toBeUndefined()
    })
  }
})

describe('wording agreed with Dan (docs/mods-design.md)', () => {
  test('the refusal names what it would print and the safe way', () => {
    expect(blockedCommand(words('echo $GITHUB_TOKEN'), '')).toBe('GITHUB_TOKEN')
    expect(commandRefusal('GITHUB_TOKEN')).toBe(
      'Blocked: this would print GITHUB_TOKEN. Check it without printing: test -n, its length, or gh auth status.',
    )
  })
  test('a .env file is named as its secrets', () => {
    expect(blockedCommand(words('cat .env'), '')).toBe('the secrets in .env')
  })
})


describe('scrubbing', () => {
  test('a known value inside a longer output is redacted', () => {
    const out = scrub(`line one\nAuthorization: Bearer ${KNOWN} trailing\n`, [KNOWN])
    expect(out.text).not.toContain(KNOWN)
    expect(out.text).toContain('[REDACTED]')
    expect(out.text).toContain('trailing')
    expect(out.count).toBe(1)
  })

  test('a percent encoded known value is redacted too (L741)', () => {
    const v = 'p@ss/w0rd+with=chars'
    const out = scrub(`https://x.test/cb?secret=${encodeURIComponent(v)}&ok=1`, [v])
    expect(out.text).not.toContain(encodeURIComponent(v))
    expect(out.text).toContain('[REDACTED]')
    expect(out.text).toContain('ok=1')
  })

  test('a never seen token is caught by its shape', () => {
    const out = scrub(`token is ${GH}`, [])
    expect(out.text).not.toContain(GH)
    expect(out.count).toBe(1)
  })

  test('a percent encoded never seen token is caught by its shape', () => {
    const jwt = 'eyJhbGciOiJIUzI1NiJ9' + '.eyJzdWIiOiIxMjM0NTY3ODkwIn0' + '.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U'
    const out = scrub(`next=${encodeURIComponent('a b ' + jwt)}`, [])
    expect(out.text).not.toContain(jwt.slice(0, 20))
    expect(out.count).toBe(1)
  })

  test('a masked token is left alone, since it is no longer the secret (L691)', () => {
    const masked = 'gho_' + '*'.repeat(36)
    const out = scrub(`Token: ${masked}`, [])
    expect(out.text).toContain(masked)
    expect(out.count).toBe(0)
  })

  test('a huge single line with no secret is scrubbed in linear time (lessons review)', () => {
    const big = 'A'.repeat(400_000) + ' tail'
    const out = scrub(big, [KNOWN])
    expect(out.count).toBe(0)
    expect(out.text.endsWith('tail')).toBe(true)
  })

  test('text with no secret is returned unchanged', () => {
    const out = scrub('nothing to see', [KNOWN])
    expect(out.text).toBe('nothing to see')
    expect(out.count).toBe(0)
  })
})

describe('outbound', () => {
  test('a known value is found in a commit message', () => {
    expect(findKnownSecret(`git commit -m "use ${KNOWN} for now"`, [KNOWN])).toBe(true)
  })
  test('a token shape is found in a gh body', () => {
    expect(findKnownSecret(`gh issue create --body "key ${GH}"`, [])).toBe(true)
  })
  test('ordinary text is not', () => {
    expect(findKnownSecret('gh issue create --body "fine"', [KNOWN])).toBe(false)
  })
  test('.env files are recognised, examples are not', () => {
    expect(isEnvFile('/repo/.env')).toBe(true)
    expect(isEnvFile('/repo/apps/web/.env.local')).toBe(true)
    expect(isEnvFile('/repo/.env.example')).toBe(false)
    expect(isEnvFile('/repo/environment.ts')).toBe(false)
  })
})

describe('value sources', () => {
  test('.env values under a secret name are taken, ordinary config is not', () => {
    const vals = secretsFromEnvText(
      `# comment\nSUPABASE_SERVICE_ROLE_KEY="${KNOWN}"\nPORT=3000\nexport API_TOKEN=${KNOWN}2\nSITE_URL=https://example.test\n`,
    )
    expect(vals).toContain(KNOWN)
    expect(vals).toContain(KNOWN + '2')
    expect(vals).not.toContain('3000')
    expect(vals).not.toContain('https://example.test')
  })
  test('a .env value shaped like a token is taken whatever its name', () => {
    expect(secretsFromEnvText(`WHATEVER=${GH}\n`)).toContain(GH)
  })
  test('environment variables named like secrets are taken, short and path values are not', () => {
    const vals = secretsFromEnvList(`GITHUB_TOKEN=${KNOWN}\nHOME=/Users/x\nSSH_KEY_PATH=/Users/x/.ssh/id\nMY_SECRET=abc\n`)
    expect(vals).toEqual([KNOWN])
  })
})

// #974: mod-kit's command reader now gives the commands a substitution runs as commands of their own,
// so a secret printed through $(...) or backticks is refused as one printed on the command line is.
// Read here with a byte for byte copy of mod-kit's reader under tests/mod-kit (a mod cannot import
// another mod's files), which tools/check-mod-shared-parts.sh holds to mod-kit's. Quoted, it is text.
describe('a command substitution, read by the real reader (#974)', () => {
  const judged = (raw: string) => blockedCommand(commands(raw), raw)
  test('what a substitution runs is judged as a command of its own', () => {
    expect(judged('echo "$(cat .env)"')).toBe('the secrets in .env')
    expect(judged('echo `printenv`')).toBe('every environment variable')
    expect(judged('cat <<EOF\n$(echo $GITHUB_TOKEN)\nEOF')).toBe('GITHUB_TOKEN')
  })
  test('in single quotes or a quoted heredoc it is text', () => {
    expect(judged("echo '$(cat .env)' '`printenv`'")).toBeUndefined()
    expect(judged("cat <<'EOF'\n$(cat .env)\nEOF")).toBeUndefined()
  })
})
