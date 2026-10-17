# frozen_string_literal: true

module Bookshelf
  module Actions
    module Books
      class Create < Hanami::Action
        def handle(_request, response)
          response.status = 201
        end
      end
    end
  end
end
