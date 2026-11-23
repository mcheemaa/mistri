# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/color_bands"

# A model sees an image a tool returns, on each provider's own wire form: an
# image block of Anthropic's tool_result, a part of OpenAI's function call
# output, inline data nested in Gemini's function response. The picture is
# four bands of color in a random order, so the answer proves the model read
# it. Run with MISTRI_LIVE=1.
class TestToolImageLive < Minitest::Test
  parallelize_me!

  PROVIDERS = { anthropic: [Mistri::Providers::Anthropic, "ANTHROPIC_API_KEY"],
                openai: [Mistri::Providers::OpenAI, "OPENAI_API_KEY"],
                gemini: [Mistri::Providers::Gemini, "GEMINI_API_KEY"] }.freeze
  PALETTE = Mistri::Test::ColorBands::COLORS.keys.freeze

  PROVIDERS.each do |name, (klass, key)|
    define_method("test_#{name}_sees_an_image_a_tool_returns") do
      assert_sees(live(klass, key)) { |picture| ["The picture:", picture] }
    end

    # Anthropic takes text alone in a failed tool_result.
    define_method("test_#{name}_sees_the_image_of_a_failed_tool") do
      assert_sees(live(klass, key)) do |picture|
        Mistri::ToolResult.new(content: ["The camera stopped after this picture:", picture],
                               error: true)
      end
    end
  end

  private

  def live(klass, key)
    skip "set MISTRI_LIVE=1" unless ENV["MISTRI_LIVE"] == "1"
    skip "no #{key}" if ENV[key].to_s.empty?
    klass.new(api_key: ENV.fetch(key))
  end

  def assert_sees(provider)
    colors = PALETTE.sample(4)
    picture = Mistri::Content::Image.from_bytes(Mistri::Test::ColorBands.png(colors),
                                                mime_type: "image/png")
    camera = Mistri::Tool.define("take_picture", "Takes a picture and returns it.") do
      yield picture
    end
    result = Mistri::Agent.new(provider:, tools: [camera]).run(
      "Call take_picture once. Its picture is four vertical bands of color. Answer with the " \
      "four colors from left to right, and nothing else. If you received no picture, " \
      "answer NONE."
    )

    assert_equal :stop, result.stop_reason, result.error_message.to_s
    assert_equal colors, result.text.downcase.scan(Regexp.union(PALETTE)),
                 "the model answered #{result.text.inspect}"
  ensure
    provider.close
  end
end
