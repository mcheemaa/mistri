# frozen_string_literal: true

module Mistri
  class Session
    # A session's entries as read so far. The log only grows and a committed
    # entry never changes, so a read asks the store for what came after the
    # entries already held. That holds only while the store says its reads are
    # settled. A store that does not say so, or says no, is read fresh and
    # nothing is held. The entries are frozen: every reader of one Session
    # shares them, from any thread.
    #
    # A checkpointed log holds only its window: the entries from the newest
    # checkpoint's kept_from on. A store that answers size is read back from
    # the end to find it; any other store is read whole and cut down here.
    class Log
      # The held entries and the position in the log of the first of them.
      Window = Data.define(:entries, :offset) do
        def position(index) = offset + index
      end

      CHUNK = 64
      private_constant :CHUNK

      def self.owned(value)
        case value
        when Hash then value.to_h { |key, nested| [owned(key), owned(nested)] }
        when Array then value.map { |nested| owned(nested) }
        when String then value.dup
        else value
        end
      end

      # A compaction that carries what the loop needs from before it.
      def self.checkpoint?(entry)
        entry["type"] == "compaction" && entry["carried"].is_a?(Hash) &&
          entry["kept_from"].is_a?(Integer) && !entry["kept_from"].negative?
      end

      attr_reader :id

      # A String id can be changed in place by its caller, so the log keeps its own.
      def initialize(store, id, checkpointed: false)
        @store = store
        @id = id.is_a?(String) ? id.dup.freeze : id
        @checkpointed = checkpointed
        @window = nil
        @mutex = Mutex.new
      end

      def entries = window.entries

      def window
        return read unless settled?

        @mutex.synchronize { @window = @window ? extended(@window) : read }
      end

      private

      def settled? = @store.respond_to?(:settled?) && @store.settled?

      def read
        return scanned if @checkpointed && @store.respond_to?(:size)

        entries = frozen(@store.load(@id)).freeze
        rebased(Window.new(entries, 0), entries)
      end

      def extended(window)
        added = frozen(@store.load(@id, from: window.position(window.entries.length)))
        return window if added.empty?

        rebased(Window.new((window.entries + added).freeze, window.offset), added)
      end

      # Checkpoints only move forward, so the newest one among the added
      # entries decides where the window starts.
      def rebased(window, added)
        return window unless @checkpointed

        start = start_in(added, window.position(window.entries.length - added.length))
        return window unless start && start > window.offset

        Window.new(window.entries.drop(start - window.offset).freeze, start)
      end

      # Reads back from the end in growing chunks until one holds a checkpoint,
      # then exactly from that checkpoint's kept_from.
      def scanned
        low = @store.size(@id)
        entries = []
        chunk = CHUNK
        until low.zero?
          from = [low - chunk, 0].max
          read = @store.load(@id, from:, to: low)
          start = start_in(read, from)
          entries = (start ? from_start(read, from, start) : read) + entries
          low = start || from
          break if start

          chunk *= 2
        end
        Window.new(frozen(entries).freeze, low)
      end

      def start_in(entries, offset)
        index = entries.rindex { |entry| Log.checkpoint?(entry) }
        index && [entries[index]["kept_from"], offset + index].min
      end

      def from_start(read, from, start)
        return read.drop(start - from) if start >= from

        @store.load(@id, from: start, to: from) + read
      end

      def frozen(entries) = entries.each { |entry| deep_freeze(entry) }

      def deep_freeze(value)
        case value
        when Hash then value.each_value { |nested| deep_freeze(nested) }
        when Array then value.each { |nested| deep_freeze(nested) }
        end
        value.freeze
      end
    end
  end
end
