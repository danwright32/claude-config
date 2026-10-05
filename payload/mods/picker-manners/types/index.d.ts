/** Whether Dan has next issue pickers off for this session; /pickers on brings them back. */
export type PickerMannersQuiet = boolean

declare module 'claude-code' {
  interface PluginState {
    /** In $.state so a reload keeps it. */
    'picker-manners': { quiet: PickerMannersQuiet }
  }
}
