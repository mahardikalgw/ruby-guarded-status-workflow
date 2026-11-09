module Tickets
  # Raised when a status change is not permitted. The controller turns the reason into a message; the
  # ticket is left untouched. One symbol per refusal is what lets the controller, the mailer and the
  # test all assert the same thing.
  class TransitionError < StandardError
    REASONS = {
      unauthorized: "helpdesk.errors.transition.unauthorized",
      illegal: "helpdesk.errors.transition.illegal",
      summary_required: "helpdesk.errors.transition.summary_required",
      reason_required: "helpdesk.errors.transition.reason_required",
      reopen_window_closed: "helpdesk.errors.transition.reopen_window_closed",
      not_manageable: "helpdesk.errors.transition.not_manageable",
      assignee_required: "helpdesk.errors.transition.assignee_required"
    }.freeze

    attr_reader :reason

    def initialize(reason)
      @reason = reason.to_sym
      super(I18n.t(REASONS.fetch(@reason, "helpdesk.errors.transition.illegal")))
    end
  end
end
