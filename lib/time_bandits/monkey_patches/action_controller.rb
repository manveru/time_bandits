require 'action_controller/metal/instrumentation'
require 'action_controller/log_subscriber'

module ActionController #:nodoc:

  module Instrumentation

    # patch to ensure that the completed line is always written to the log
    def process_action(action, *args)
      TimeBandits.reset

      raw_payload = {
        :controller => self.class.name,
        :action     => self.action_name,
        :params     => request.filtered_parameters,
        :formats    => request.formats.map(&:to_sym),
        :method     => request.method,
        :path       => (request.fullpath rescue "unknown")
      }

      ActiveSupport::Notifications.instrument("start_processing.action_controller", raw_payload.dup)

      exception = nil
      result = ActiveSupport::Notifications.instrument("process_action.action_controller", raw_payload) do |payload|
        begin
          super
        rescue Exception => exception
          response.status = 500
          nil
        ensure
          payload[:status] = response.status
          append_info_to_payload(payload)
        end
      end
      raise exception if exception
      result
    end

    # patch to ensure that render times are always recorded in the log
    def render(*args)
      render_output = nil
      exception = nil
      self.view_runtime = cleanup_view_runtime do
        Benchmark.ms do
          begin
            render_output = super
          rescue Exception => exception
          end
        end
      end
      raise exception if exception
      render_output
    end

    def cleanup_view_runtime #:nodoc:
      consumed_before_rendering = TimeBandits.consumed
      runtime = yield
      consumed_during_rendering = TimeBandits.consumed - consumed_before_rendering
      runtime - consumed_during_rendering
    end
  end

  class LogSubscriber
    def process_action(event)
      payload   = event.payload
      additions = ActionController::Base.log_process_action(payload)

      message = "Completed #{payload[:status]} #{Rack::Utils::HTTP_STATUS_CODES[payload[:status]]} in %.0fms" % event.duration
      message << " (#{additions.join(" | ")})" unless additions.blank?

      info message
    end
  end

  module TimeBanditry #:nodoc:
    extend ActiveSupport::Concern

    module ClassMethods
      def log_process_action(payload) #:nodoc:
        messages = super
        TimeBandits.time_bandits.each do |bandit|
          messages << bandit.runtime
        end
        messages
      end
    end

  end
end
