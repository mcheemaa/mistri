# frozen_string_literal: true

require_relative "test_helper"

class TestImageData < Minitest::Test
  # Every provider refuses base64 with line breaks, and two of them refuse the
  # other forms.
  def test_an_image_holds_strict_base64_whatever_form_it_was_given_in
    bytes = "\x89PNG\r\n\x1A\n".b + ("\xFB\xFF\xFE picture ".b * 20)
    strict = [bytes].pack("m0").freeze
    padded = strict.dup.tap { |text| text[-2] = text[-2].succ }
    forms = { "strict" => strict, "MIME lines" => [bytes].pack("m"),
              "CRLF lines" => strict.scan(/.{1,76}/).join("\r\n"),
              "a newline in front" => "\n#{strict}", "no padding" => strict.delete("="),
              "URL-safe" => strict.tr("+/", "-_"),
              "URL-safe, no padding" => strict.tr("+/", "-_").delete("="),
              "pad bits set" => padded }

    forms.each do |form, text|
      image = Mistri::Content::Image.new(data: text, mime_type: "image/png")

      assert_equal strict, image.data, form
      assert_equal bytes, image.bytes, form
    end

    assert_same strict, Mistri::Content::Image.new(data: strict, mime_type: "image/png").data
    assert_equal strict, Mistri::Content.from_h("type" => "image", "data" => forms["MIME lines"],
                                                "mime_type" => "image/png").data
  end

  def test_a_stored_image_is_read_strict_and_its_entry_is_left_as_it_was
    store = Mistri::Stores::Memory.new
    lines = ["a picture of some length, long enough for a second line".b * 2].pack("m")
    store.append("s", { "type" => "message", "message" => {
                   "role" => "user",
                   "content" => [{ "type" => "image", "data" => lines, "mime_type" => "image/png" }]
                 } })

    image = Mistri::Session.new(store:, id: "s").messages.first.content.first

    assert_equal lines.delete("\n"), image.data
    assert_equal lines, store.load("s").first.dig("message", "content", 0, "data")
  end

  def test_an_image_stays_strict_through_with_and_never_raises_on_other_text
    image = Mistri::Content::Image.from_bytes("picture", mime_type: "image/png")

    assert_equal image.data, image.with(data: ["picture"].pack("m")).data
    assert_equal "image/gif", image.with(mime_type: "image/gif").mime_type

    broken = "\xFF\xD8 not base64".dup.force_encoding("UTF-8")
    [nil, "", "data:image/png;base64,!!", broken].each do |text|
      data = Mistri::Content::Image.new(data: text, mime_type: "image/png").data

      assert_equal data, [data.unpack1("m0")].pack("m0"), text.inspect
    end
  end
end
