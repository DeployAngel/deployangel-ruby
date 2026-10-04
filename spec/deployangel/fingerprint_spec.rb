# frozen_string_literal: true

RSpec.describe DeployAngel::Fingerprint do
  let(:root) { "/app" }

  def exception_with(backtrace, klass: NoMethodError, message: "undefined method 'total' for nil")
    klass.new(message).tap { |e| e.set_backtrace(backtrace) }
  end

  it "uses the first application frame, without line numbers" do
    error = exception_with([
      "/usr/local/bundle/gems/activerecord-8.1.0/lib/active_record/base.rb:10:in 'save'",
      "/app/app/services/order_creator.rb:42:in 'block in OrderCreator#call'",
      "/app/app/controllers/orders_controller.rb:7:in 'OrdersController#create'"
    ])

    expect(described_class.top_frame(error, root: root)).to eq("app/services/order_creator.rb#call")
  end

  it "is stable when lines move, gems upgrade, or messages change" do
    before_deploy = exception_with([ "/usr/local/bundle/gems/sidekiq-7.3.4/lib/sidekiq/x.rb:1:in 'run'",
                                     "/app/app/jobs/sync_job.rb:12:in 'SyncJob#perform'" ], message: "id 12 missing")
    after_deploy = exception_with([ "/usr/local/bundle/gems/sidekiq-8.0.1/lib/sidekiq/x.rb:9:in 'run'",
                                    "/app/app/jobs/sync_job.rb:30:in 'SyncJob#perform'" ], message: "id 99 missing")

    expect(described_class.for(before_deploy, root: root)["fingerprint"])
      .to eq(described_class.for(after_deploy, root: root)["fingerprint"])
  end

  it "differs by exception class and application frame" do
    base = described_class.for(exception_with([ "/app/app/models/order.rb:1:in 'Order#total'" ]), root: root)
    other_class = described_class.for(exception_with([ "/app/app/models/order.rb:1:in 'Order#total'" ], klass: ArgumentError), root: root)
    other_frame = described_class.for(exception_with([ "/app/app/models/cart.rb:1:in 'Cart#total'" ]), root: root)

    expect([ other_class["fingerprint"], other_frame["fingerprint"] ]).not_to include(base["fingerprint"])
  end

  it "falls back to a version-free gem frame when no application frame exists" do
    error = exception_with([ "/usr/local/bundle/gems/redis-client-0.22.1/lib/redis_client.rb:5:in 'call'" ])

    expect(described_class.top_frame(error, root: root)).to eq("redis-client/lib/redis_client.rb#call")
    expect(described_class.for(error, root: root)["app_frame"]).to be(false)
  end

  it "strips IDs, emails, and quoted values from messages" do
    message = described_class.normalize_message("User 42 (pat@example.com) not found: 'abc' 0x7f3a")

    expect(message).to eq("User <n> (<email>) not found: <string> <hex>")
  end

  it "keeps unquoted words, which only turning messages off removes" do
    expect(described_class.normalize_message("Payment of 1250.00 failed for Jane Doe"))
      .to eq("Payment of <n> failed for Jane Doe")
  end

  it "replaces redactions as whole words, ignoring case, before anything else" do
    redactions = [ [ "acme.lendwell.com", "<host>" ], [ "acme", "<tenant>" ] ]

    expect(described_class.normalize_message("Blocked host: ACME.lendwell.com for acme_x, not acmeco", redactions))
      .to eq("Blocked host: <host> for <tenant>_x, not acmeco")
  end

  it "keeps only application frames in representative backtraces" do
    error = exception_with([ "/usr/local/bundle/gems/rack-3.1.0/lib/rack.rb:1:in 'call'",
                             "/app/app/controllers/orders_controller.rb:7:in 'OrdersController#create'" ])

    expect(described_class.backtrace(error, root: root)).to eq([ "app/controllers/orders_controller.rb#create" ])
  end
end
