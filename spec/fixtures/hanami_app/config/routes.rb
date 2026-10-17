# frozen_string_literal: true

module Bookshelf
  class Routes < Hanami::Routes
    get "/books/:id", to: "books.show"
    post "/books", to: "books.create"
    get "/boom", to: "books.boom"
    scope "api" do
      get "/v1/books/:id", to: "books.show"
    end
    get "/healthz", to: ->(_env) { [200, {}, ["ok"]] }
    get "/status", to: ->(_env) { [200, {}, ["ok"]] }

    slice :admin, at: "/admin" do
      get "/reports/:id", to: "reports.show"
    end
  end
end
