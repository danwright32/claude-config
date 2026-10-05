/** A tool call as a `tool.call` hook receives it: the tool, the call's id, and its arguments beside them. Plain data. */
export type SecretGuardCall = { tool: string; tool_use_id?: string } & Record<string, unknown>

/** Called from another mod (mod-kit's screen, #707): await it. */
export type SecretGuard = {
  /**
   * The check this mod's tool.call hook makes, for a call a mod answers itself and so never passes
   * down to that hook: a command that would print a secret, or input carrying a known secret or a
   * token's shape. Refused, it draws the grey card under the call's id and toasts, as the hook does,
   * and answers the refusal the caller returns; null when the call carries none.
   */
  screen: (call: SecretGuardCall) => Promise<{ deny: string } | null>
}

declare module 'claude-code' {
  interface EngineInterface {
    secretGuard: SecretGuard
  }
}
