# frozen_string_literal: true

module Bookshelf
  module Actions
    module Books
      class Show < Hanami::Action
        def handle(_request, response)
          DeployAngel.checkpoint("book.viewed")
          response.body = "book"
        end
      end
    end
  end
end
