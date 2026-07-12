# frozen_string_literal: true

module Mistri
  # A sub-agent as its parent (or the host UI) sees it: a window onto the
  # child's own session. Everything here is derived from the store, so it
  # reads the same from any process, while the child runs and forever after.
  #
  #   session.children            # => [#<Mistri::Child Magpie done>, ...]
  #   child.status                # queued, running, interrupted, or terminal
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
    # Work currently scheduled or queued, used for capacity and steering.
    # Interrupted work is nonterminal but not actively live.
    LIVE = %i[running queued].freeze

    attr_reader :name, :session_id

    def self.lease_key(session_id) = "child:#{session_id}"

    def self.stop_key(session_id) = "child-stop:#{session_id}"

    def initialize(name:, session_id:, store:, parent_session_id: nil)
      @name = name
      @session_id = session_id
      @store = store
      @parent_session_id = parent_session_id
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

    # A terminal entry exists: the child ended as done, stopped, or failed,
    # so a later matching delivery must not run it again. The inverse
    # (started but no terminal) is what makes a crashed child re-runnable.
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

    # Ask a child to stop, from any process. An inactive dispatched child is
    # cancelled durably under its lease; an inline or already-running child
    # receives the stop flag. Repeating stop on a stopped dispatched child
    # reconciles a missing parent report. Stop is
    # cross-process by nature, so it needs a lock adapter; without one this
    # returns false. An action that reports acceptance, not a predicate.
    def stop # rubocop:disable Naming/PredicateMethod
      return false unless Mistri.locks

      outcome = cancel_inactive
      Mistri.locks.set_flag(self.class.stop_key(@session_id)) if outcome == :contended
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

    # Cancellation and a runner compete for the same lease. Acquiring it
    # proves no unexpired lease is present, so ordinary inactive dispatched
    # work can end here; a stale holder may still resume under the documented
    # tokenless lease trade-off. Status cannot be rechecked because our own
    # lease would read running.
    def cancel_inactive
      key = self.class.lease_key(@session_id)
      lease = Locks.hold(key)
      return :contended unless lease

      begin
        log = session.entries
        terminal = log.reverse_each.find { |entry| entry["type"] == TERMINAL }
        dispatched = log.any? { |entry| entry["type"] == DISPATCHED }
        if terminal
          deliver_cancellation if terminal["status"] == "stopped"
          :finished
        elsif dispatched
          session.append(TERMINAL, "status" => "stopped")
          deliver_cancellation
          :cancelled
        else
          Mistri.locks.set_flag(self.class.stop_key(@session_id))
          :signaled
        end
      ensure
        lease.release
      end
    end

    # A cancelled queue item may never be delivered, so the lease owner
    # must route its durable outcome. Current versions trust only the stored
    # grant; legacy children fall back to the parent link because their
    # dispatched entry did not retain a spec.
    def deliver_cancellation
      dispatched = session.entries.find { |entry| entry["type"] == DISPATCHED }
      return unless dispatched

      spec = dispatched["spec"]
      parent_id, label = cancellation_route(spec)
      return unless parent_id.is_a?(String) && !parent_id.empty?
      return unless label.is_a?(String) && !label.empty?

      Session.new(store: @store, id: parent_id)
             .deliver_report(name: label, session_id: @session_id, status: "stopped")
    end

    def cancellation_route(spec)
      return [@parent_session_id, @name] if spec.nil?
      return [nil, nil] unless spec.is_a?(Hash)
      return [nil, nil] unless spec["spec_version"] == SubAgent::DISPATCH_SPEC_VERSION
      return [nil, nil] unless spec["session_id"] == @session_id

      [spec["parent_session_id"], spec["name"]]
    end

    def session
      @session ||= Session.new(store: @store, id: @session_id)
    end

    def terminal_entry
      session.entries.reverse_each.find { |entry| entry["type"] == TERMINAL }
    end
  end
end
