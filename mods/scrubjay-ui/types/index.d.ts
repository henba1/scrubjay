export type StepState = 'run' | 'ok' | 'fail' | 'skip'

/** One step of a scrubjay run, at its last reported state. */
export type SjStep = { name: string; state: StepState; detail: string }

/** A run as bin/lib.sh records it in ~/.scrubjay/run/<op>.tsv (sj_progress_begin … sj_progress_end). */
export type SjRun = {
  op: string
  label: string
  startedAt: number
  endedAt?: number
  steps: SjStep[]
  /** Followed without the person asking (the SessionStart sync): the band stays out of it. */
  isQuiet: boolean
  /** When the band last redrew it, for the elapsed counter and the spinner frame. */
  now: number
}

/** What the current /sj* command is doing, for the band while no run is being followed. */
export type SjActivity = { command: string; line: string; tone: 'run' | 'ok' | 'warn' | 'error'; at: number }

declare module 'claude-code' {
  interface PluginState {
    'scrubjay-ui': { run: SjRun | null; activity: SjActivity | null }
  }
}
