module Tickets
  # The only way a status changes. One transaction covers the status, its timestamps, the event row and
  # the notification; a refused transition can never leave a half-applied record behind.
  class TransitionStatus
    def initialize(ticket:, actor:, status:, resolution_summary: nil, reason: nil)
      @ticket = ticket
      @actor = actor
      @status = status.to_s
      @resolution_summary = resolution_summary.to_s.strip
      @reason = reason.to_s.strip
      @previous_status = ticket.status
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

    private
      attr_reader :ticket, :actor, :status, :resolution_summary, :reason, :previous_status

      def permitted_actors
        Ticket::TRANSITIONS.dig(previous_status, status) || []
      end

      def permitted_actor?
        return false if permitted_actors.empty?
        return permitted_actors.include?("requester") if actor.requester?

        permitted_actors.include?(actor.role) && Ticket.manageable_by(actor).exists?(ticket.id)
      end

      # A resolution needs a summary once; a re-resolution keeps the first one recorded.
      def requires_summary?
        status == "resolved" && ticket.resolved_at.nil? && resolution_summary.blank?
      end

      # Staff justify a closure that ends a resolved request. A requester closing their own does not.
      def requires_reason?
        return false if actor.requester?

        (status == "cancelled" || (status == "closed" && previous_status == "resolved")) && reason.blank?
      end

      # "In progress" means somebody owns the work — except when a requester's reply resumes the
      # conversation, which is not a colleague starting work.
      def requires_assignee?
        return false unless status == "in_progress" && actor.staff?
        return false if ticket.assigned_agent_id.present?

        previous_status != "waiting_requester"
      end

      def requester_reopen?
        actor.requester? && %w[resolved closed].include?(previous_status) && status != "closed"
      end

      def reopenable?
        settings = HelpdeskSetting.for(ticket.workspace)
        settings.reopen_days.positive? && ticket.resolved_at.present? &&
          ticket.resolved_at > settings.reopen_days.days.ago
      end

      def persist
        ActiveRecord::Base.transaction do
          ticket.status = status
          ticket.resolution_summary = resolution_summary if resolution_summary.present?
          ticket.resolved_at ||= Time.current if status == "resolved"
          ticket.closed_at ||= Time.current if status == "closed"
          ticket.last_activity_at = Time.current
          ticket.save!

          TicketEvent.record!(
            workspace: ticket.workspace, ticket: ticket, actor: actor, event_type: event_type,
            previous: { from_status: previous_status, reason: reason },
            new: { to_status: status }
          )
        end

        notify
        ticket
      end

      def event_type
        return "ticket_reopened" if previous_status == "resolved" && status == "in_progress"

        "status_changed"
      end

      # After the commit: a mailer failure must not roll back a status the agent already set.
      def notify
        kind = { "waiting_requester" => "information_requested",
                 "resolved" => "ticket_resolved",
                 "closed" => "ticket_closed" }[status]
        return if kind.nil?

        Tickets::Notify.call(ticket: ticket, kind: kind, actor: actor)
      end
  end
end
