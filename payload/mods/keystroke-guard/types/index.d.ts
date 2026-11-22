/**
 * Each dialog this mod has open that it raised itself (#3321), as one string, kept by mod-kit's
 * recorder (hooks/mod-kit/asked.ts) for as long as the dialog is open and written nowhere else.
 */
export type KeystrokeGuardAsking = string[]

declare module 'claude-code' {
  interface PluginState {
    /**
     * In $.state, which only this mod can write: picker manners reads `asking` to tell this mod's
     * own Ready question from a session's picker. A new session starts with none.
     */
    'keystroke-guard': { asking: KeystrokeGuardAsking }
  }
}
