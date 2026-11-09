# A worked transition matrix

## States

| State | Means | Terminal |
|---|---|---|
| `open` | filed, nobody owns it yet | no |
| `in_progress` | a named person is working on it | no |
| `waiting_requester` | staff asked a question and stopped | no |
| `waiting_third_party` | blocked on a vendor or another unit | no |
| `resolved` | the fix is stated; the requester has not confirmed | no (reopenable within a window) |
| `closed` | the conversation ended | yes (an administrator can reopen) |
| `cancelled` | refused as invalid or duplicated | yes (an administrator can reopen) |

## The matrix

| from \ to | open | in_progress | waiting_requester | waiting_third_party | resolved | closed | cancelled |
|---|---|---|---|---|---|---|---|
| **open** | — | staff | staff | staff | staff | requester, supervisor, admin | supervisor, admin |
| **in_progress** | staff | — | staff | staff | staff | requester, supervisor, admin | supervisor, admin |
| **waiting_requester** | staff | requester, staff | — | staff | staff | requester, supervisor, admin | supervisor, admin |
| **waiting_third_party** | staff | staff | staff | — | staff | requester, supervisor, admin | supervisor, admin |
| **resolved** | supervisor, admin | requester, staff | — | — | — | requester, staff | supervisor, admin |
| **closed** | supervisor, admin | — | — | — | — | — | — |
| **cancelled** | supervisor, admin | — | — | — | — | — | — |

"staff" = `agent`, `team_leader`, `supervisor`, `admin` — each additionally constrained by
`manageable_by`.

## Why each unusual edge exists

- **Every working state returns to `open`.** A card picked up by mistake, or handed to the wrong team, is
  returned to the queue rather than cancelled and re-filed. Without this edge the only way out of a
  mis-triage is an audit trail full of cancellations.
- **The requester can close but not cancel.** Closing is "I no longer need this"; cancelling is "this was
  never valid", which is a judgement the queue owner makes.
- **The requester can reopen inside the window** — `resolved` → `in_progress`, and `closed` → `open`.
  Closing by mistake must not be a dead end for the person who made the mistake.
- **A closed ticket is otherwise reopened by a supervisor or administrator.** Closing is the end of the
  conversation; if the requester still needs something, that is a new request or an administrator's
  decision.
- **`waiting_requester` → `in_progress` by staff is exempt from the assignee guard.** The requested
  information arrived; the conversation is resuming, not a colleague starting work.

## Guards per edge

| Edge | Guard | Symbol |
|---|---|---|
| → `resolved` | `resolution_summary` present (or already recorded) | `summary_required` |
| → `cancelled` | `reason` present (staff only) | `reason_required` |
| `resolved` → `closed` | `reason` present when the actor is staff | `reason_required` |
| → `in_progress` from unassigned, by staff | an `assigned_agent_id` exists | `assignee_required` |
| requester `resolved` → `in_progress` | `resolved_at > reopen_days.ago` | `reopen_window_closed` |
| any edge not in the map | — | `illegal` |
| any edge whose role list excludes the actor | — | `unauthorized` |


## The tests that pin it

```ruby
class TransitionStatusTest < ActiveSupport::TestCase
  test "an illegal pair is refused with :illegal" do
    assert_raises(TransitionError) { move(@ticket, to: "banana", actor: @agent) }
  end

  test "resolving without a summary is refused" do
    error = assert_raises(TransitionError) { move(@ticket, to: "resolved", actor: @agent) }
    assert_equal :summary_required, error.reason
    assert_equal "open", @ticket.reload.status
  end

  test "a resolved ticket with a summary is not asked for another one" do
    ticket = create_ticket(workspace: @workspace, requester: @requester, status: "resolved",
                           resolution_summary: "Sudah direset.")
    move(ticket, to: "closed", actor: @agent, reason: "Selesai")
    assert_equal "closed", ticket.reload.status
  end

  test "an unassigned ticket cannot enter in_progress" do
    error = assert_raises(TransitionError) { move(@ticket, to: "in_progress", actor: @agent) }
    assert_equal :assignee_required, error.reason
  end

  test "a requester reopen outside the window is refused" do
    ticket = create_ticket(workspace: @workspace, requester: @requester, status: "resolved",
                           resolution_summary: "Reset.", resolved_at: 40.days.ago)
    error = assert_raises(TransitionError) { move(ticket, to: "in_progress", actor: @requester) }
    assert_equal :reopen_window_closed, error.reason
  end

  test "a legal move writes exactly one event and one notification" do
    assert_difference -> { TicketEvent.where(event_type: "status_changed").count }, 1 do
      assert_difference -> { Notification.where(kind: "ticket_resolved").count }, 1 do
        move(@ticket, to: "resolved", actor: @agent, resolution_summary: "Sudah direset.")
      end
    end
  end

  test "a re-resolution keeps the first resolved_at" do
    @ticket.update!(resolved_at: 3.days.ago)
    move(@ticket, to: "resolved", actor: @agent, resolution_summary: "Reset ulang.")
    assert_in_delta 3.days.ago, @ticket.reload.resolved_at, 1.minute
  end

  private
    def move(ticket, to:, actor:, **attrs)
      Tickets::TransitionStatus.new(ticket: ticket, actor: actor, status: to, **attrs).call
    end
end
```

## Controller shape

```ruby
class TicketStatusesController < ApplicationController
  def update
    ticket = Ticket.manageable_by(Current.user).find_by!(ticket_number: params[:ticket_number])
    Tickets::TransitionStatus.new(
      ticket: ticket, actor: Current.user, status: params[:status],
      resolution_summary: params[:resolution_summary], reason: params[:reason]
    ).call

    redirect_to ticket_path(ticket.ticket_number), status: :see_other, notice: I18n.t("helpdesk.status_updated")
  rescue Tickets::TransitionError => e
    redirect_to ticket_path(ticket.ticket_number), status: :see_other, inertia: { errors: { status: e.message } }
  end
end
```

The rescue is the whole error surface: one symbol-to-message mapping, one refusal path, and the ticket is
untouched because every guard raises before `persist`.
