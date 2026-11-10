# frozen_string_literal: true

# Small steps for building a session by hand in a test. The including test
# sets @session and @store.
module SessionScripts
  def fresh = Mistri::Session.new(store: @store, id: "s")

  def exchange(text, session = @session)
    session.append_message(Mistri::Message.user(text))
    session.append_message(Mistri::Message.assistant(content: text.upcase, stop_reason: :stop))
  end

  def link(name, session_id, session = @session)
    session.append("subagent", "name" => name, "session_id" => session_id)
  end

  def call(id)
    tool_call = Mistri::ToolCall.new(id:, name: "ping", arguments: {})
    @session.append_message(Mistri::Message.assistant(tool_calls: [tool_call]))
    @session.append_message(Mistri::Message.tool(content: "pong", tool_call_id: id,
                                                 tool_name: "ping"))
  end

  def fold(entry)
    marker = Mistri::Session::INBOX.fetch(entry["type"])
    @session.append("message", "message" => entry["message"], marker => entry["id"])
  end

  def compact(session = @session)
    summarizer = Mistri::Providers::Fake.new(turns: [{ text: "Summary." }])
    Mistri::Compactor.call(session:, provider: summarizer,
                           settings: Mistri::Compaction.new(keep_recent: 1))
  end
end
