# Auth-stub profile files

This directory is where a *publicly shippable, sanitized* profile file could
live — but **this plugin ships no real profiles here**. A profile's
`required_methods` list can be specific and identifying to a particular
company's internal SDK, so real profiles are treated as private, machine-local
data instead.

See `skills/verify/SKILL.md`'s "Auth-stub injection (opt-in)" section for the
full config schema and validation rules. In short:

## Two-location lookup order

When a `.claude/visual-verify.auth-stub.json` config names a `profile`,
`scripts/auth-stub.sh` looks up `<profile-name>.json` in, in this order:

1. **Private, machine-local, never committed:**
   `~/.claude/plugins/data/visual-verify/profiles/<profile-name>.json`
2. **Bundled with this plugin (fallback):** this directory,
   `visual-verify/profiles/<profile-name>.json` — empty by policy; see above.

The first location that has a *valid* profile file for the requested name
wins. If neither does, validation reports `stub_config.status:
"unrecognized_profile"` (nested under `stub_config` in `detect-env.sh`'s output, not a flat
`stub_config_status` field).

## Creating your own profile

Create `~/.claude/plugins/data/visual-verify/profiles/<your-sdk-name>.json`
(private, machine-local, never touched by git) shaped like
`example.schema.json` in this directory — that file is documentation only,
with fake method names, not a real profile.

If you want to contribute a genuinely generic, sanitized profile for a widely
used open-source auth SDK, open a PR adding it to this directory instead.
