# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# The base gathers what no framework owns. Nothing here stubs Rails, so a
# Rails dependency creeping back into DeployAngel::Metadata fails these.
RSpec.describe DeployAngel::Metadata do
  let(:config) { DeployAngel::Configuration.new({}) }

  around do |example|
    Dir.mktmpdir do |root|
      @root = root
      example.run
    end
  end

  def metadata(environment: "production")
    described_class.new(config: config, root: @root, environment: environment)
  end

  def write(relative, contents)
    path = File.join(@root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
    path
  end

  it "names no routes or job classes, which only a framework can answer" do
    expect(metadata.routes).to eq([])
    expect(metadata.job_classes).to eq([])
    expect(metadata.to_protocol).to include("routes" => [], "job_classes" => [])
  end

  it "reads a sidekiq-cron schedule file the app loads itself, rendering its ERB" do
    stub_const("Sidekiq::Cron", Module.new)
    config.sidekiq_cron_schedule_file = write("config/sidekiq_schedule.yml.erb", <<~SCHEDULE)
      nightly:
        cron: "0 0 * * *"
        class: "NightlyWorker"
        status: "<%= 'enabled' %>"
      paused:
        cron: "0 1 * * *"
        class: "PausedWorker"
        status: "disabled"
    SCHEDULE

    expect(metadata.schedules.map { |job| job.slice("key", "class", "schedule", "source") }).to eq(
      [ { "key" => "nightly", "class" => "NightlyWorker", "schedule" => "0 0 * * *", "source" => "sidekiq_cron" } ]
    )
  end

  it "sends work scheduled outside the app from config.recurring_jobs, read in the server's zone" do
    config.recurring_jobs = { "NightlyInvoiceJob" => "0 3 * * *", "rake invoices:send" => "every day at 4am", "blank" => " " }
    reader = metadata
    allow(reader).to receive(:local_time_zone).and_return("America/New_York")

    expect(reader.schedules).to eq([
      { "key" => "NightlyInvoiceJob", "class" => "NightlyInvoiceJob", "schedule" => "0 3 * * *", "source" => "config",
        "time_zone" => "America/New_York" },
      { "key" => "rake invoices:send", "class" => "rake invoices:send", "schedule" => "every day at 4am", "source" => "config",
        "time_zone" => "America/New_York" }
    ])
  end

  describe "the whenever gem's config/schedule.rb" do
    it "sends rake tasks and job runners as cron lines, the way whenever writes the crontab" do
      write("config/schedule.rb", <<~SCHEDULE)
        set :output, "log/cron.log"
        every 1.day, at: "4:30 am" do
          rake "invoices:send"
          runner "NightlyInvoiceJob.perform_now"
        end
        every :monday, at: ["2:00 am", "3:00 pm"] do
          runner "Reports::WeeklyJob.set(queue: :low).perform_later"
        end
        every 15.minutes do
          runner "Cache.warm!"
          command "/usr/bin/backup"
        end
        every :reboot do
          rake "boot:check"
        end
      SCHEDULE

      expect(metadata.schedules.map { |job| job.slice("key", "class", "schedule", "source") }).to eq([
        { "key" => "rake invoices:send", "class" => "rake invoices:send", "schedule" => "30 4 * * *", "source" => "whenever" },
        { "key" => "NightlyInvoiceJob", "class" => "NightlyInvoiceJob", "schedule" => "30 4 * * *", "source" => "whenever" },
        { "key" => "Reports::WeeklyJob (0 2 * * 1)", "class" => "Reports::WeeklyJob", "schedule" => "0 2 * * 1", "source" => "whenever" },
        { "key" => "Reports::WeeklyJob (0 15 * * 1)", "class" => "Reports::WeeklyJob", "schedule" => "0 15 * * 1", "source" => "whenever" }
      ])
    end

    it "leaves the other schedules in place when the file can't be read" do
      write("config/schedule.rb", "every 1.day do
  rake 'x'
")
      config.recurring_jobs = { "NightlyJob" => "0 3 * * *" }

      expect(metadata.schedules.map { |job| job["key"] }).to eq([ "NightlyJob" ])
    end
  end

  it "filters sidekiq-scheduler jobs by the environment it was given" do
    stub_const("SidekiqScheduler", Module.new)
    write("config/sidekiq.yml", <<~CONFIG)
      :scheduler:
        :schedule:
          here:
            cron: "0 2 * * *"
            class: "HereWorker"
          elsewhere:
            cron: "0 3 * * *"
            class: "ElsewhereWorker"
            rails_env: staging, development
    CONFIG

    expect(metadata.schedules.map { |job| job["key"] }).to eq([ "here" ])
    expect(metadata(environment: "staging").schedules.map { |job| job["key"] }).to contain_exactly("here", "elsewhere")
  end

  it "digests the folders an adapter names, for a framework laid out differently" do
    write("app/models/user.rb", "class User; end")
    write("slices/billing/actions/charge.rb", "class Charge; end")
    write("config/app.rb", "App = 1")
    adapter = Class.new(described_class) do
      def digest_globs = %w[slices/**/* config/**/*]
    end

    files = adapter.new(config: config, root: @root, environment: "production").files
    expect(files.keys).to eq([ "config/app.rb", "slices/billing/actions/charge.rb" ])
  end

  it "digests files by path and hash, never their contents" do
    write("app/models/user.rb", "class User; end\n")
    write("Gemfile.lock", "GEM\n")

    expect(metadata.to_protocol["file_manifest"]).to include("count" => 2, "truncated" => false)
    expect(metadata.to_protocol["file_manifest"]["hash"]).to match(/\A[0-9a-f]{64}\z/)
    expect(metadata.files.keys).to contain_exactly("app/models/user.rb", "Gemfile.lock")
    expect(metadata.files.values).to all(match(/\A[0-9a-f]{16}\z/))
  end

  it "carries critical flows through as strings" do
    config.critical_flows = { password_reset: [ "POST /password_resets", :"job:PasswordsMailer" ] }

    expect(metadata.to_protocol["critical_flows"]).to eq(
      "password_reset" => [ "POST /password_resets", "job:PasswordsMailer" ]
    )
  end
end
