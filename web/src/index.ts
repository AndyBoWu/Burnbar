// Production Worker entry: the app wired with the real GitHub verifier.
// Routes + handlers live in src/app.ts (createApp is injected with fakes in tests).
export { app as default } from './app'
export type { Env } from './app'
