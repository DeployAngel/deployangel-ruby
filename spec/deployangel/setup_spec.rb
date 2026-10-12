# frozen_string_literal: true

require "tmpdir"

RSpec.describe "deployangel setup and token" do
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }

  around { |example| Dir.mktmpdir { |root| @root = root; example.run } }

  # Answers a setup code like the server: the app and its two tokens, once.
  let(:redeemer) do
    Class.new do
      attr_reader :codes

      def initialize = @codes = []

      def redeem_setup_code(code)
        @codes << code
        raise DeployAngel::Client::NotFound, "That setup code is invalid, already used, or expired." unless code == "da_setup_good"

        { "app" => { "id" => 7, "name" => "shop", "environment" => "production" },
          "app_token" => "da_live_apptoken", "api_token" => "da_live_apitoken" }
      end
    end.new
  end

  def cli(*argv, client: nil, env: {})
    DeployAngel::CLI.new(argv, env: env, stdout: stdout, stderr: stderr, client: client, root: @root)
  end

  it "redeems a code and saves both tokens privately, out of git, without printing either" do
    expect(cli("setup", "--code=da_setup_good", client: redeemer).run).to eq(0)

    file = File.join(@root, ".deployangel/credentials.json")
    expect(JSON.parse(File.read(file))).to include("app_token" => "da_live_apptoken", "api_token" => "da_live_apitoken",
      "app" => include("name" => "shop"))
    expect(File.stat(file).mode & 0o777).to eq(0o600)
    expect(File.read(File.join(@root, ".deployangel/.gitignore"))).to eq("*\n")
    expect(stdout.string).to include("Set up DeployAngel for shop (production)", "not shown here", "token app)",
      "reads its token only from DEPLOYANGEL_TOKEN", "setup-for-agents.md")
    expect(stdout.string).not_to include("fly secrets", "heroku config:set")
    expect(stdout.string + stderr.string).not_to include("da_live_")
  end

  it "uses the saved token for every command when DEPLOYANGEL_API_TOKEN isn't set, and the environment's when it is" do
    cli("setup", "--code=da_setup_good", client: redeemer).run

    expect(cli.send(:client).instance_variable_get(:@token)).to eq("da_live_apitoken")
    expect(cli(env: { "DEPLOYANGEL_API_TOKEN" => "da_live_env" }).send(:client).instance_variable_get(:@token)).to eq("da_live_env")

    nested = File.join(@root, "app", "models")
    FileUtils.mkdir_p(nested)
    expect(DeployAngel::Credentials.read(nested)["api_token"]).to eq("da_live_apitoken")
  end

  it "prints a saved token with nothing around it, for piping into a host's secrets" do
    cli("setup", "--code=da_setup_good", client: redeemer).run
    stdout.truncate(0)
    stdout.rewind

    expect(cli("token", "app").run).to eq(0)
    expect(stdout.string).to eq("da_live_apptoken")
  end

  it "says what's wrong with a bad code, a missing code, or nothing saved" do
    expect(cli("setup", "--code=da_setup_used", client: redeemer).run).to eq(4)
    expect(stderr.string).to include("invalid, already used, or expired")
    expect(File.exist?(File.join(@root, ".deployangel"))).to be(false)

    expect(cli("setup", client: redeemer).run).to eq(5)
    expect(cli("token", "app").run).to eq(5)
    expect(stderr.string).to include("run deployangel setup --code=<code> first")
    expect(cli("token", "nope").run).to eq(5)
  end
end
