# frozen_string_literal: true

module Bookshelf
  module Actions
    module Books
      class Boom < Hanami::Action
        def handle(_request, _response)
          raise ArgumentError, "Book 42 exploded"
        end
      end
    end
  end
end
