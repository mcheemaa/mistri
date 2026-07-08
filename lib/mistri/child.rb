# frozen_string_literal: true

module Mistri
  # A sub-agent as its parent (or the host UI) sees it: a window onto the
  # child's own session. Everything here is derived from the store, so it
  # reads the same from any process, while the child runs and forever after.
  #
  #   session.children            # => [#<Mistri::Child Magpie done>, ...]
  #   child.status                # => :running, :done, :stopped, :failed
  #   child.report                # the terminal entry's report, once finished
  #   child.transcript(tail: 20)  # recent entries, image bytes stripped
  #   child.say("Also check their pricing page")
  #
  # Status is a walk over the child's own entries: a terminal entry wins; a
  # started child is :running while its lease holds and :interrupted once
  # it lapses (with a lock adapter; without one there is no liveness signal
  # and no-terminal stays :running); a dispatched-but-never-started child is
  # :queued, honestly, because the host's queue owns that gap.
  class Child
    TERMINAL = "subagent_result"
    DISPATCHED = "subagent_dispatched"
    STARTED = "subagent_started"
    # The states a worker can still be caught in: steerable, stoppable,
    # worth waiting on.
    LIVE = %i[running queued].freeze

    attr_reader :name, :session_id

    def self.lease_key(session_id) = "child:#{session_id}"

    def self.stop_key(session_id) = "child-stop:#{session_id}"

    def initialize(name:, session_id:, store:)
      @name = name
      @session_id = session_id
      @store = store
    end

    def status
      log = session.entries
      terminal = log.reverse_each.find { |entry| entry["type"] == TERMINAL }
      return terminal["status"].to_sym if terminal
      if log.any? { |entry| entry["type"] == DISPATCHED } &&
         log.none? { |entry| entry["type"] == STARTED }
        return :queued
      end
      return :interrupted if Mistri.locks && !Mistri.locks.held?(self.class.lease_key(@session_id))

      :running
    end

    # A terminal entry exists: the child ended as done, stopped, or failed
    # and will never run again. The question a queue retry asks; its
    # inverse (started but no terminal) is what makes a crashed child
    # re-runnable.
    def finished?
      !terminal_entry.nil?
    end

    def report
      terminal_entry&.fetch("report", nil)
    end

    # The terminal entry's error string, once failed.
    def error
      terminal_entry&.fetch("error", nil)
    end

    # Recent entries, oldest first, with inline image bytes replaced by a
    # marker: transcripts are for reading and re-sending, not for hauling
    # screenshots back into a context window.
    def transcript(tail: 20)
      entries = session.entries
      entries = entries.last(tail) if tail
      entries.map { |entry| self.class.strip_images(entry) }
    end

    # Queue a message the child folds at its next turn boundary. Delivery is
    # honest, not instant: a child mid-step sees it after that step, and a
    # child that finishes first never sees it.
    def say(text)
      session.steer(text)
    end

    # Ask a live child to stop, from any process. A running child's runner
    # sees the flag within a tick and trips its own signal; a queued child
    # is cancelled outright with a stopped terminal, which the runner
    # honors by never starting it. Stop is cross-process by nature, so it
    # needs a lock adapter; without one this returns false. An action that
    # reports acceptance, not a predicate.
    def stop # rubocop:disable Naming/PredicateMethod
      return false unless Mistri.locks

      session.append(TERMINAL, "status" => "stopped") if status == :queued
      Mistri.locks.set_flag(self.class.stop_key(@session_id))
      true
    end

    def to_h
      { "name" => name, "session_id" => session_id, "status" => status.to_s }
    end

    def inspect
      "#<Mistri::Child #{name} #{status}>"
    end

    def self.strip_images(value)
      case value
      when Hash
        if value["data"] && value["mime_type"]
          value.except("data").merge("omitted" => true)
        else
          value.transform_values { |nested| strip_images(nested) }
        end
      when Array then value.map { |nested| strip_images(nested) }
      else value
      end
    end

    private

    def session
      @session ||= Session.new(store: @store, id: @session_id)
    end

    def terminal_entry
      session.entries.reverse_each.find { |entry| entry["type"] == TERMINAL }
    end
  end
end
