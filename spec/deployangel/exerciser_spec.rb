# frozen_string_literal: true

require "spec_helper"

RSpec.describe DeployAngel::Exerciser do
  def fill(path, params)
    described_class.new(base_url: "https://shop.example.com", params: params).fill(path)
  end

  it "fills each framework's path parameters by name" do
    expect(fill("/apps/:app_id/deployments/:id", "app_id" => "3", "id" => "212")).to eq([ "/apps/3/deployments/212", [] ])
    expect(fill("/items/{item_id}", "item_id" => "9")).to eq([ "/items/9", [] ])
    expect(fill("/orders/{id:int}/lines/{line?}", "id" => "4", "line" => "2")).to eq([ "/orders/4/lines/2", [] ])
    expect(fill("/orders/<int:pk>/", "pk" => "5")).to eq([ "/orders/5/", [] ])
  end

  it "names the parameters it couldn't fill, once each" do
    expect(fill("/apps/:app_id/deployments/:id", "id" => "212")).to eq([ "/apps/:app_id/deployments/212", [ "app_id" ] ])
    expect(fill("/a/:id/b/:id", {})).to eq([ "/a/:id/b/:id", [ "id" ] ])
  end

  it "escapes values, keeping slashes only in parameters that span segments" do
    expect(fill("/users/:id", "id" => "a b/c")).to eq([ "/users/a%20b%2Fc", [] ])
    expect(fill("/pages/*id", "id" => "about/team")).to eq([ "/pages/about/team", [] ])
    expect(fill("/files/{*path}", "path" => "a/b")).to eq([ "/files/a/b", [] ])
    expect(fill("/files/{path:path}", "path" => "a/b")).to eq([ "/files/a/b", [] ])
    expect(fill("/docs/<path:rest>", "rest" => "x/y")).to eq([ "/docs/x/y", [] ])
  end

  it "reads --param and header values, and never puts a header's value in an error" do
    expect(described_class.parse_params([ "id=42", "slug=a=b" ])).to eq("id" => "42", "slug" => "a=b")
    expect { described_class.parse_params([ "id=" ]) }.to raise_error(ArgumentError, /name=value/)
    expect(described_class.parse_headers([ "Authorization:  Bearer x ", "", "Cookie: a=b" ])).to eq("Authorization" => "Bearer x", "Cookie" => "a=b")
    expect { described_class.parse_headers([ "Cookie s3cret" ]) }.to raise_error(ArgumentError) { |e| expect(e.message).not_to include("s3cret") }
    expect { described_class.parse_headers([ "X: a\r\nHost: evil" ]) }.to raise_error(ArgumentError)
  end
end
