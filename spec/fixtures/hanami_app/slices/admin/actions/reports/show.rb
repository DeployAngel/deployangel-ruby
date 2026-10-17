# frozen_string_literal: true

module Admin
  module Actions
    module Reports
      class Show < Hanami::Action
        def handle(_request, response)
          response.body = "report"
        end
      end
    end
  end
end
