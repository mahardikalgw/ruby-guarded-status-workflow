# Guarded status workflow

Build a guarded state machine for a Rails workflow — a declarative transition map as the single source of truth, a service object that validates the actor and the fields each edge requires, one transaction with an immutable event row, and notifications that fire after the commit. Use when adding or changing statuses, approvals, or any lifecycle with required data per transition.

One skill, one repository. Part of a twelve-skill pack extracted from a production Rails 8 +
Inertia + React helpdesk monolith — the opinionated layer no public Rails or shadcn skill can know.
Version `2.0.0` tracks the source constitution.

## Install

```jsonc
// skills-lock.json
{
  "version": 1,
  "skills": {
    "guarded-status-workflow": {
      "source": "mahardikalgw/guarded-status-workflow",
      "sourceType": "github",
      "skillPath": "SKILL.md"
    }
  }
}
```

Or clone and symlink:

```bash
git clone git@github.com:mahardikalgw/guarded-status-workflow.git
ln -s "$PWD/guarded-status-workflow" .claude/skills/guarded-status-workflow
```

## When to activate

- Adding a status, stage, or lifecycle to a model.
- Changing who may perform a transition.
- A status change needs extra data (a reason, a summary, an assignee).
- A "cannot be undone" or "only within N days" rule appears.
- Reviewing a state change that is spread across a controller and a callback.

## What's inside

```
guarded-status-workflow/
  SKILL.md
  assets/transition_error.rb
  assets/transition_status.rb
  references/transition-matrix.md
```

`SKILL.md` is a router (kept under 250 lines) — the depth lives in `references/`, and the
copy-in code lives in `assets/`.

## Validate

```bash
./bin/check-skill
```

Checks frontmatter, the activation section, link resolution, orphaned references, script
executability, leftover placeholders, and — when the source app is checked out next to this
repository — that vendored scripts still match it byte for byte. Runs in CI on every push.

## Related skills

- [`scoped-authorization`](https://github.com/mahardikalgw/scoped-authorization) — scopes, 404-not-403, explicit public opt-outs, isolation by construction
- [`inertia-test-harness`](https://github.com/mahardikalgw/inertia-test-harness) — minitest + inertia helpers, builder objects, and system tests that do not flake

## Licence

MIT — see [LICENSE](LICENSE).
