# frozen_string_literal: true

module DeployAngel
  module Rails
    # Receives Rails.error reports, for handled errors only (Rails.error.handle
    # and Rails.error.report(handled: true)), shown for context.
    #
    # Rails also reports unhandled request and job exceptions here, before the
    # middleware and job instrumentation see them. Those paths record them
    # with their route or job class, so unhandled reports are skipped here.
    class ErrorSubscriber
      def report(error, handled:, **)
        DeployAngel.record_exception(error, handled: true) if handled
      rescue StandardError
        nil
      end
    end
  end
end
