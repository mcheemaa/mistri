# frozen_string_literal: true

module Mistri
  module MCP
    # One request, and what a server sends while the client waits for its
    # answer: a notice, a request of its own, an answer to another request,
    # or nothing. Part of Client, which gives it the wire.
    module Conversation
      private

      # The wait for an answer can be ended from outside the gem: by a tool's
      # own limit, or by a Timeout the host put around the call. That cancels
      # the request and keeps the server, as the read timeout does. A request
      # that was not sent has nothing to cancel. In each case the request got
      # no answer, and the time of the first such request is kept.
      def exchange(payload, replayable, **, &)
        settled = false
        @wire.call(payload, replayable: replayable, **, &)
        settled = true
      rescue WireTimeout
        @unanswered_at ||= clock
        settled = true
        raise
      rescue Mistri::Error, NotSent
        settled = true
        raise
      ensure
        unless settled
          @unanswered_at ||= clock
          cancel(payload[:method], payload[:id], "the caller stopped waiting")
        end
      end

      # A request with no answer leaves a doubt about a server this client
      # started. Before the next request the server is asked a question that
      # changes nothing. One that answers was slow, and is kept with all it
      # holds. One that does not is ended, and the request starts a new one.
      # A question that the caller ends leaves the doubt as old as it was.
      def end_if_gone
        gone = @wire.restartable? && @wire.open? && !sign_of_life?
        @unanswered_at = nil
        return unless gone

        warn("mistri: the MCP server gave no sign of life after a request with no answer, " \
             "so it was ended")
        @wire.close
      end

      # The question is ping, or server/discover since 2026-07-28, which has
      # no ping. Any answer to it counts, a refusal too. The time is for the
      # answer: other messages do not extend it. A question that fails is no
      # sign of life, and not the failure of the request that comes after it.
      def sign_of_life?
        id = (@serial += 1)
        question = { jsonrpc: "2.0", id: id, method: stateless? ? "server/discover" : "ping" }
        question[:params] = { _meta: described } if stateless?
        exchange(question, true, wait: time_left, whole: true) { |record| answer_in(record, id) }
        true
      rescue Mistri::Error
        false
      end

      # The server has the read timeout to give a sign of life, counted from
      # the request that got no answer. So a server that handles one request
      # at a time can first finish that request, and a caller whose own limit
      # ends the question still ends a server that is gone, at a later
      # request. A question asked after that time still gets a short wait of
      # its own. With no read timeout the question has no limit of its own.
      def time_left
        limit = @wire.read_timeout
        limit && [limit - (clock - @unanswered_at), @wire.probe_wait].max
      end

      def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # A record with a method is the server's own request or notice, whatever
      # its id. The answer may carry the id as a string of the same digits.
      def answer_in(record, id)
        return unless record.is_a?(Hash)
        return reply_to(record) if record.key?("method") && record.key?("id")
        return noticed(record) if record.key?("method")

        record if [id, id.to_s].include?(record["id"])
      end

      # A notice goes to the host as the server sent it. What the host's
      # callable raises is not the server's failure, so the call goes on. A
      # tool's limit that passes while the host is told still ends the call.
      def noticed(record)
        @on_notification&.call(record["method"], record["params"])
        nil
      rescue StandardError => e
        raise if ToolExecutor.deadline?(e)

        warn("mistri: on_notification failed (#{e.class}: #{e.message})")
        nil
      end

      # A call asks for progress with a token, which is its own id, so it is
      # unique among the calls in flight.
      def meta_of(method, id, newest)
        meta = newest ? described : {}
        meta[:progressToken] = id if @progress && method == "tools/call"
        meta
      end

      # An error is raised once its response was read to the end, so the
      # connection it came on is kept.
      def outcome(answer)
        @unanswered_at = nil
        @state = :connected
        @failure = nil
        raise rpc_error(answer["error"]) if answer["error"]

        typed(answer["result"])
      end

      # This client declares no capability, so ping is the one request it
      # serves. A reply that cannot be delivered does not fail the call. Since
      # 2026-07-28 a server sends no request and a client no reply.
      def reply_to(record)
        id = record["id"]
        return if stateless?
        return unless id.is_a?(Integer) || (id.is_a?(String) && id.valid_encoding?)

        reply = if record["method"] == "ping"
                  { result: {} }
                else
                  { error: { code: -32_601, message: "Method not found" } }
                end
        @wire.notify({ jsonrpc: "2.0", id: id, **reply })
        nil
      rescue Mistri::Error
        nil
      end

      # The handshake is the one request the spec forbids a client to cancel.
      def cancel(method, id, reason)
        return if method == "initialize"

        @wire.cancel({ jsonrpc: "2.0", method: "notifications/cancelled",
                       params: { requestId: id, reason: reason } })
      rescue Mistri::Error
        nil
      end

      def unanswered(method, replayable)
        detail = "the server sent no matching response to #{method}"
        return Error.new(detail) if replayable

        AmbiguousDeliveryError.new("#{AmbiguousDeliveryError.default_message}: #{detail}")
      end

      def unconfirmed(error)
        "the request was sent but its tool outcome could not be confirmed: " \
          "#{error.message}; the operation may have completed; do not retry automatically; " \
          "verify external state first"
      end
    end
  end
end
