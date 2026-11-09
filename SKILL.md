---
name: guarded-status-workflow
description: Build a guarded state machine for a Rails workflow — a declarative transition map as the single source of truth, a service object that validates the actor and the fields each edge requires, one transaction with an immutable event row, and notifications that fire after the commit. Use when adding or changing statuses, approvals, or any lifecycle with required data per transition.
version: 2.0.0
---

# Guarded status workflow

A workflow is not a string column with a dropdown. It is a **transition map** (who may move where), a
**requirement per edge** (what must be supplied to move), and an **event row** (what happened, and by
whom). All three live on the server, and the map is data rather than a chain of `if`s.

## When to activate

- Adding a status, stage, or lifecycle to a model.
- Changing who may perform a transition.
- A status change needs extra data (a reason, a summary, an assignee).
- A "cannot be undone" or "only within N days" rule appears.
- Reviewing a state change that is spread across a controller and a callback.

## 1. The map is the source of truth

```ruby
class Ticket < ApplicationRecord
  STATUSES = %w[open in_progress waiting_requester waiting_third_party resolved closed cancelled].freeze
  FINAL_STATUSES = %w[closed cancelled].freeze

  # from => { to => [roles allowed] }. "requester" is listed where the requester may move their own
  # ticket; the service additionally checks the reopen window for that actor.
  TRANSITIONS = {
    "open" => {
      "in_progress"       => %w[agent team_leader supervisor admin],
      "waiting_requester" => %w[agent team_leader supervisor admin],
      "resolved"          => %w[agent team_leader supervisor admin],
      "closed"            => %w[requester supervisor admin],
      "cancelled"         => %w[supervisor admin]
    },
    "resolved" => {
      "open"              => %w[supervisor admin],
      "in_progress"       => %w[requester agent team_leader supervisor admin],
      "closed"            => %w[agent team_leader supervisor admin requester]
    },
    "closed" => { "open" => %w[supervisor admin] },
    "cancelled" => { "open" => %w[supervisor admin] }
  }.freeze

  def self.allowed_transitions(from, role)
    TRANSITIONS.fetch(from, {}).select { |_to, roles| roles.include?(role) }.keys
  end
end
```

Why a constant and not a policy gem: the map is small, it belongs next to the states it describes, and a
reviewer can read the whole workflow in one screen. A gem adds a DSL for a table that fits in forty lines.

Why the UI renders buttons from the map: `allowed_transitions(ticket.status, user.role)` is the same
answer the service enforces, so a button can never offer a move that will be refused.

## 2. The service enforces every edge

```ruby
module Tickets
  class TransitionStatus
    def initialize(ticket:, actor:, status:, resolution_summary: nil, reason: nil)
      @ticket = ticket
      @actor = actor
      @status = status.to_s
      @previous_status = ticket.status
      @resolution_summary = resolution_summary.to_s.strip
      @reason = reason.to_s.strip
    end

    def call
      raise TransitionError, :illegal unless Ticket::STATUSES.include?(status)
      raise TransitionError, :unauthorized unless permitted_actor?
      raise TransitionError, :summary_required if requires_summary?
      raise TransitionError, :reason_required if requires_reason?
      raise TransitionError, :assignee_required if requires_assignee?
      raise TransitionError, :reopen_window_closed if requester_reopen? && !reopenable?

      persist
    end
  end
end
```

## 3. Requirements belong to the edge, not the status

| Requirement | Applies when | Why |
|---|---|---|
| `summary_required` | moving to `resolved` and nothing is recorded yet | A resolution without a summary is a closed ticket nobody can explain |
| `reason_required` | moving to `cancelled`, or `closed` from `resolved` **by staff** | A refusal needs a justification; a requester closing their own request does not |
| `assignee_required` | moving to `in_progress` by staff, from an unassigned ticket | "In progress" means somebody owns the work |
| `reopen_window_closed` | a requester moving `resolved` → `in_progress` outside `reopen_days` | The window is a policy, not a UI nicety |

Each guard is a small private predicate. Writing them as one `case status` block is how an edge gets
forgotten.

```ruby
def permitted_actors
  Ticket::TRANSITIONS.dig(previous_status, status) || []
end

def permitted_actor?
  return false if permitted_actors.empty?
  return permitted_actors.include?("requester") if actor.requester?

  permitted_actors.include?(actor.role) && Ticket.manageable_by(actor).exists?(ticket.id)
end
```

Two checks, not one: the role must be listed for this edge **and** the actor must be able to manage this
row. A role-only check lets a team leader move a ticket in a team they do not lead.

## 4. One transaction: state, timestamps, event

```ruby
def persist
  ActiveRecord::Base.transaction do
    ticket.status = status
    ticket.resolution_summary = resolution_summary if resolution_summary.present?
    ticket.resolved_at ||= Time.current if status == "resolved"
    ticket.closed_at   ||= Time.current if status == "closed"
    ticket.last_activity_at = Time.current
    ticket.save!

    TicketEvent.record!(workspace: ticket.workspace, ticket: ticket, actor: actor,
                        event_type: event_type,
                        previous: { from_status: previous_status, reason: reason },
                        new: { to_status: status })
  end

  notify
  ticket
end
```

- Timestamps use `||=` so a re-resolution keeps the original `resolved_at`. A re-resolved ticket that
  resets its timestamp destroys the audit trail of the first resolution.
- The event row is inside the transaction: a state change with no event row is an audit hole. Make the
  event table append-only — no `update`, no `destroy`, enforced by a model callback that raises.
- `notify` runs **after** the commit, so a mailer failure cannot roll back a status the agent just set.

## 5. Derived, never typed twice

```ruby
def event_type
  return "ticket_reopened" if previous_status == "resolved" && status == "in_progress"
  "status_changed"
end

def notify
  kind = { "waiting_requester" => "information_requested",
           "resolved" => "ticket_resolved",
           "closed" => "ticket_closed" }[status]
  return if kind.nil?

  Tickets::Notify.call(ticket: ticket, kind: kind, actor: actor)
end
```

The notification kind is derived from the target status in one place. A caller passing `kind:` invites
two call sites to disagree.

## 6. Idempotency and the second writer

- A requester's public reply may resume a ticket (`waiting_requester` → `in_progress`). Do that inside
  the comment service and swallow the refusal: the reply must save even when the window is closed.
- Two agents clicking "resolve" at once: the second call finds `resolved` → `resolved` absent from the
  map and refuses. No duplicate event row, no duplicate mail.
- A job that changes status must carry an actor. There is no "system" transition that bypasses the map;
  either use the administrator the job runs as, or add the edge explicitly.

## Done when

1. `TRANSITIONS` covers every state pair a user can reach, including the ones that exist to undo a
   mistake.
2. Every guard has a locale key and a service test asserting the symbol.
3. A status change writes exactly one event row and at most one notification.
4. The page builds its buttons from `allowed_transitions`, so the UI and the service agree.
5. A re-resolution does not overwrite the first resolution's timestamps.

## References

- [references/transition-matrix.md](references/transition-matrix.md) — a full worked matrix with guards and tests
- [assets/transition_status.rb](assets/transition_status.rb) — the service to adapt
- [assets/transition_error.rb](assets/transition_error.rb) — typed errors mapped to locale keys

