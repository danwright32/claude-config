import { describe, expect, test } from 'claude-code/testing'
import {
  blockedCommandReason,
  findKnownSecret,
  isEnvFile,
  scrub,
  secretsFromEnvText,
  secretsFromEnvList,
} from '../hooks/secrets.ts'

// Fixture values built at run time so this file holds no literal token shape of its own.
const GH = 'ghp_' + 'A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8'
const KNOWN = 'kN0wn-S3cr3t-v4lue-zz'

describe('blocked commands', () => {
  const blocked: [string, string][] = [
    ['cat .env', 'cat .env'],
    ['cat a project .env.local by path', 'cat apps/web/.env.local'],
    ['head of .env', 'head -5 .env'],
    ['echo a token variable', 'echo $GITHUB_TOKEN'],
    ['echo a braced key variable', 'echo "${OPENAI_API_KEY}"'],
    ['printf a secret', 'printf "%s" "$DB_PASSWORD"'],
    ['bare printenv', 'printenv'],
    ['printenv a secret by name', 'printenv SLACK_TOKEN'],
    ['bare env', 'env'],
    ['gh auth token printed', 'gh auth token'],
    ['gh auth token echoed through a substitution', 'echo $(gh auth token)'],
    ['a secret command after a harmless one', 'ls && cat .env'],
  ]
  for (const [name, cmd] of blocked) {
    test(`refuses ${name}`, () => {
      const why = blockedCommandReason(cmd)
      expect(why).toBeDefined()
      // The refusal names the safe form, not just the refusal (L111).
      expect(why ?? '').toMatch(/test -n|length|\$\{#/)
    })
  }

  const allowed: [string, string][] = [
    ['a presence check', '[ -n "$GITHUB_TOKEN" ] && echo set'],
    ['the length of a secret', 'echo ${#GITHUB_TOKEN}'],
    ['printenv of an ordinary variable', 'printenv PATH'],
    ['env running a command', 'env FOO=1 make build'],
    ['gh auth token captured into a variable', 'GH_TOKEN=$(gh auth token -u danwright32) gh pr list'],
    ['gh auth status', 'gh auth status'],
    ['cat of an example env file', 'cat .env.example'],
    ['echo of an ordinary variable', 'echo $HOME'],
    ['cat of an unrelated file', 'cat README.md'],
  ]
  for (const [name, cmd] of allowed) {
    test(`allows ${name}`, () => {
      expect(blockedCommandReason(cmd)).toBeUndefined()
    })
  }
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
