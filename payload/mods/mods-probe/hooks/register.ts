import type { Register } from 'claude-code'

// Temporary probe for claude-config#606: records that a session on this Mac loaded the mods.
export const register: Register = (on) => {
  on('session.start', async ($, e, next) => {
    await $.fs.write('/tmp/mods-probe-loaded.txt', `loaded ${new Date().toISOString()}\n`)
    return next(e)
  })
}
