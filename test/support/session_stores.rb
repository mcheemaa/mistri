# frozen_string_literal: true

# Store doubles for tests of how a session or a worker window reads its log.
module SessionStores
  # Records each load and signals when it has finished.
  class Recording < Mistri::Stores::Memory
    Read = Data.define(:id, :from, :entries)

    attr_reader :loaded

    def initialize
      super
      @reads = []
      @loaded = Queue.new
    end

    def reads(id = nil)
      id ? @reads.select { |read| read.id == id } : @reads
    end

    def load(id, from: 0, to: nil)
      super.tap do |entries|
        @reads << Read.new(id:, from:, entries: entries.length)
        @loaded << true
      end
    end
  end

  # Appends made inside #transaction vanish when it is rolled back.
  class Transactional < Mistri::Stores::Memory
    class Rollback < StandardError; end

    def settled? = !@open

    def transaction
      saved = @mutex.synchronize { @entries.to_h { |id, entries| [id, entries.dup] } }
      @open = true
      yield
    rescue Rollback
      @mutex.synchronize { @entries.each_key { |id| @entries[id] = saved.fetch(id, []) } }
    ensure
      @open = false
    end
  end

  # Serves the thread that pinned it the log as it was then, like REPEATABLE READ.
  class Snapshot < Mistri::Stores::Memory
    def pin
      copy = @mutex.synchronize { @entries.to_h { |id, entries| [id, entries.dup] } }
      Thread.current.thread_variable_set(:pinned, copy)
    end

    def unpin = Thread.current.thread_variable_set(:pinned, nil)

    def settled? = Thread.current.thread_variable_get(:pinned).nil?

    def load(id, from: 0, to: nil)
      pinned = Thread.current.thread_variable_get(:pinned)
      return super unless pinned

      pinned.fetch(id, [])[from...to].to_a.map { |entry| json_copy(entry, freeze: false) }
    end
  end

  # A store written before partial reads: append and load(id), nothing else.
  class Plain
    attr_reader :loads

    def initialize
      @store = Mistri::Stores::Memory.new
      @loads = 0
    end

    def append(id, entry) = @store.append(id, entry)

    def load(id)
      @loads += 1
      @store.load(id)
    end
  end

  # Holds one load inside the store until the test lets it go.
  class Gated < Mistri::Stores::Memory
    attr_reader :entered, :starts

    def initialize
      super
      @entered = Queue.new
      @gate = Queue.new
      @starts = []
    end

    def hold_next_load = @hold = true

    def release = @gate << true

    def load(id, from: 0, to: nil)
      @starts << from
      if @hold
        @hold = false
        @entered << true
        @gate.pop
      end
      super
    end
  end
end
