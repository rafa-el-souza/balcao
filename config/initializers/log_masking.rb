# An error's message never reaches the log (threat model SR-30): it may quote
# what a visitor wrote, as a database error quotes the row it refused
# ("Failing row contains (…)"), and the log outlives the deletion (FR-05) and
# the seven-day purge (FR-15). The app's own lines name an error by its class
# alone (ProcessTurnJob, TurnProcessor, AgentTool, TraceRecorder); these give
# Rails' own error lines the same rule, keeping the class, which says what
# broke, and the backtrace, which names only code:
#
# - Active Job's lines of a failed, retried, stopped or discarded job and of a
#   step that failed ("Error performing", "Retrying", "Stopped retrying",
#   "Discarded", "Error during step"), and of an enqueue that failed;
# - a request's error, which ActionDispatch::DebugExceptions writes with its
#   message and its causes' (production's error page shows neither);
# - Solid Queue's worker lines, which write the error a job's last attempt
#   raises on to the worker ("Error in thread") and a failure to finish a
#   job, whose FinalizationError quotes its cause (review finding C1 of pull
#   request #29).
#
# The error itself is left as it was: only the line is written from a copy.
module Balcao
  module LogMasking
    FILTERED = "[FILTERED]".freeze

    module_function

    # A copy of the error, of its class and with its backtrace, whose message
    # is FILTERED (Exception#exception); an error whose class computes its
    # message anyway, or refuses to be copied, is written as a RuntimeError
    # that names that class, so the line is never lost.
    def error(error)
      masked = error.exception(FILTERED)
      return masked if masked.message == FILTERED

      stand_in(error)
    rescue StandardError
      stand_in(error)
    end

    def stand_in(error)
      RuntimeError.new("#{FILTERED} #{error.class}").tap { |copy| copy.set_backtrace(error.backtrace) if error.backtrace }
    end

    # The event as Active Job's log subscriber reads it, with its error
    # masked; the payload the other subscribers read stays as it was.
    def event(event)
      errors = event.payload.slice(:exception_object, :error).compact
      return event if errors.empty?

      event.dup.tap { |copy| copy.payload = event.payload.merge(errors.transform_values { |error| error(error) }) }
    end

    module JobLines
      %i[enqueue enqueue_at perform enqueue_retry retry_stopped discard step].each do |name|
        define_method(name) { |event| super(LogMasking.event(event)) }
      end
    end

    # ActionDispatch::DebugExceptions' line of a request's error.
    module RequestLines
      private

      def compose_exception_message(wrapper) = super(MaskedWrapper.new(wrapper))
    end

    # SolidQueue::LogSubscriber's every error attribute.
    module QueueLines
      private

      def formatted_error(error) = error.class.name
    end

    class MaskedWrapper < SimpleDelegator
      def message = FILTERED

      def wrapped_causes = __getobj__.wrapped_causes.map { |cause| MaskedWrapper.new(cause) }
    end
  end
end

ActiveSupport.on_load(:active_job) { ActiveJob::LogSubscriber.prepend(Balcao::LogMasking::JobLines) }
ActionDispatch::DebugExceptions.prepend(Balcao::LogMasking::RequestLines)
SolidQueue::LogSubscriber.prepend(Balcao::LogMasking::QueueLines)
