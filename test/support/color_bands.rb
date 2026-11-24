# frozen_string_literal: true

require "zlib"

module Mistri
  module Test
    # A PNG of vertical bands of color, drawn here so the suite holds no
    # binary file. A live test returns it from a tool and asks for the colors
    # in order, which a model can only read from the picture.
    module ColorBands
      COLORS = { "red" => [220, 0, 0], "green" => [0, 140, 0], "blue" => [0, 0, 220],
                 "yellow" => [255, 215, 0], "black" => [0, 0, 0] }.freeze
      BAND = 160
      HEIGHT = 240

      module_function

      def png(names)
        scanline = "\x00".b + names.flat_map { |name| COLORS.fetch(name) * BAND }.pack("C*")
        header = [names.length * BAND, HEIGHT, 8, 2, 0, 0, 0].pack("NNCCCCC")
        "\x89PNG\r\n\x1a\n".b + chunk("IHDR", header) +
          chunk("IDAT", Zlib::Deflate.deflate(scanline * HEIGHT)) + chunk("IEND", "".b)
      end

      def chunk(type, data)
        [data.bytesize].pack("N") + type + data + [Zlib.crc32(type + data)].pack("N")
      end
    end
  end
end
