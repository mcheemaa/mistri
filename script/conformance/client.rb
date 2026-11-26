# frozen_string_literal: true

# Mistri's MCP client under the official conformance suite. The suite starts a
# scenario server and runs this file with the server's address as the last
# argument, the scenario in MCP_CONFORMANCE_SCENARIO and its data in
# MCP_CONFORMANCE_CONTEXT. Run it with `bundle exec rake conformance`.
#
# Mistri leaves the sign-in loop to the host, so this file is the smallest
# host. On a refused token it starts a sign-in, follows the redirect a browser
# would, and completes it with the callback's iss. Like a host it keeps the
# client it registered, drops it when the server names another authorization
# server, and after a 403 for more scope signs in again with what it was
# granted and what is asked. MISTRI_CONFORMANCE_TOLERANT=1 turns tolerant
# discovery on, which the 2025-03-26 revision needs.
require "json"
require "net/http"
require "uri"
require "mistri"

class ConformanceClient
  OAUTH = Mistri::MCP::OAuth
  LOOPBACK = ->(_uri, address) { address.loopback? }
  NAME = "mistri-conformance"
  REDIRECT = "http://127.0.0.1:53682/callback"
  # The suite's fixed address for a client ID metadata document.
  DOCUMENT = "https://conformance-test.local/client-metadata.json"
  SIGN_INS = 3
  RESOURCES = ["file:///path/to/file%20name.txt", "https://example.com/resource?id=123"].freeze
  STATE_TOOLS = %w[test_mrtr_echo_state test_mrtr_unrelated test_mrtr_no_state
                   test_mrtr_no_result_type].freeze

  def initialize(url, scenario:, context:, tolerant:)
    @url = url
    @scenario = scenario
    @context = context
    @tolerant = tolerant
    @sign_ins = 0
    @client = Mistri::MCP::Client.new(url: url, token: -> { @token }, client_name: NAME,
                                      allow_non_public: LOOPBACK, read_timeout: 20)
  end

  # A refusal by the gem is an outcome the suite judges, not a crash.
  def run
    signed_in { @client.connect }
    exercise(signed_in { @client.tools })
    say("done")
  rescue Mistri::Error => e
    say("the client ended with #{e.class}: #{e.message[0, 400]}")
  ensure
    @client.close
  end

  private

  def exercise(tools)
    case @scenario
    when "tools_call" then call("add_numbers", { "a" => 1, "b" => 2 })
    when "sse-retry" then call("test_reconnection")
    when "elicitation-sep1034-client-defaults" then call("test_client_elicitation_defaults")
    when "json-schema-2020-12-preservation" then echo_schema(tools)
    when "sep-2322-client-request-state" then STATE_TOOLS.each { |name| call(name) }
    when "http-custom-headers" then calls_of_the_scenario
    when "http-invalid-tool-headers" then call("valid_tool", { "message" => "hello" })
    when "http-standard-headers" then headers(tools)
    when "auth/scope-step-up" then call(named(tools, "test-tool"))
    end
  end

  def echo_schema(tools)
    focal = tools.find { |tool| tool["name"] == "json_schema_2020_12_tool" }
    raise "json_schema_2020_12_tool was not listed" unless focal

    call("json_schema_echo", { "schema" => focal["inputSchema"] })
  end

  def calls_of_the_scenario
    (@context["toolCalls"] || []).each { |wanted| call(wanted["name"], wanted["arguments"] || {}) }
  end

  def headers(tools)
    call(named(tools, "test_headers"))
    RESOURCES.each do |uri|
      say("read #{uri}: #{JSON.generate(signed_in { @client.read_resource(uri) })[0, 200]}")
    rescue Mistri::Error => e
      say("read #{uri}: #{e.class}: #{e.message[0, 200]}")
    end
  end

  def named(tools, name) = (tools.find { |tool| tool["name"] == name } || tools.first).fetch("name")

  def call(name, arguments = {})
    result = signed_in { @client.call_tool(name, arguments) }
    say("#{name}: #{JSON.generate(result)[0, 300]}")
  end

  def signed_in
    yield
  rescue Mistri::AuthenticationError => e
    raise if @sign_ins >= SIGN_INS

    @sign_ins += 1
    asked = OAUTH.challenge(e)
    more = OAUTH.step_up_scope(@granted, asked["scope"]) if asked["error"] == "insufficient_scope"
    say("sign-in #{@sign_ins} after #{e.status}#{" for the scope #{more.inspect}" if more}")
    sign_in(more)
    retry
  end

  def sign_in(scope)
    flow = start(scope)
    @stored = flow.slice("client_id", "client_secret", "token_auth_method", "issuer")
                  .transform_keys(&:to_sym)
    answer = approve(flow.fetch("authorize_url"))
    raise "the state does not match" unless answer["state"] == flow.fetch("state")
    raise "the authorization failed: #{answer["error"]}" unless answer["code"]

    tokens = OAUTH.complete(code: answer.fetch("code"), iss: answer["iss"], tolerant: @tolerant,
                            allow_non_public: LOOPBACK, **flow.transform_keys(&:to_sym))
    @granted = tokens["scope"] || flow["scope"]
    @token = tokens.fetch("access_token")
  end

  # A client the suite hands over is one set up by hand. One this file
  # registered is kept, and dropped when the server names another issuer.
  def start(scope)
    options = { url: @url, client_name: NAME, redirect_uri: REDIRECT, scope: scope,
                allow_non_public: LOOPBACK, client_metadata_url: DOCUMENT,
                offline_access: true, tolerant: @tolerant }
    OAUTH.start(**options, **(given || @stored || {}))
  rescue OAUTH::IssuerChanged
    raise if given || @stored.nil?

    say("the server names another authorization server, so the stored client is dropped")
    @stored = nil
    OAUTH.start(**options)
  end

  def given
    return unless @context["client_id"]

    found = OAUTH.discover(url: @url, allow_non_public: LOOPBACK, tolerant: @tolerant)
    { client_id: @context["client_id"], client_secret: @context["client_secret"],
      token_auth_method: @context["token_endpoint_auth_method"], issuer: found["issuer"] }
  end

  # What a browser does with the address: the suite's server redirects at once.
  def approve(authorize_url)
    response = Net::HTTP.get_response(URI(authorize_url))
    location = response["location"]
    raise "the authorization endpoint answered #{response.code} with no redirect" unless location

    URI.decode_www_form(URI(location).query.to_s).to_h
  end

  def say(text) = warn("[mistri-conformance] #{text}")
end

raw = begin
  JSON.parse(ENV.fetch("MCP_CONFORMANCE_CONTEXT", "{}"))
rescue JSON::ParserError
  {}
end
ConformanceClient.new(ARGV.last, scenario: ENV.fetch("MCP_CONFORMANCE_SCENARIO"),
                                 context: raw["context"].is_a?(Hash) ? raw["context"] : raw,
                                 tolerant: ENV["MISTRI_CONFORMANCE_TOLERANT"] == "1").run
