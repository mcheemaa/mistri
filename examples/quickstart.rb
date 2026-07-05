# frozen_string_literal: true

# A tool-using agent, streamed. Needs ANTHROPIC_API_KEY.
#
#   ruby examples/quickstart.rb

require "mistri"

weather = Mistri::Tool.define(
  "get_weather", "Current weather for a city.",
  schema: -> { string :city, "City name", required: true }
) do |args|
  "34C and clear in #{args["city"]}"
end

agent = Mistri.agent("claude-opus-4-8", tools: [weather])

agent.run("What should I wear in Lahore today? One sentence.") do |event|
  print event.delta if event.type == :text_delta
end
puts
