# frozen_string_literal: true

module Mistri
  # The management console: the tools an agent gets for managing the workers
  # it spawns. Every tool is a thin wrapper over Session#children and the
  # Child facade, the same functions a host UI calls, so nothing the agent
  # can do is hidden from the user and nothing the user does confuses the
  # agent. Tools are stateless: each call reads the calling session's
  # children at that moment.
  #
  #   agent = Mistri::Agent.new(provider:, tools: [spawn, *Mistri::Console.tools])
  #
  # Workers are addressed by name or session id, uniformly, in every tool.
  # When two workers share a name, the most recently spawned one answers;
  # ids stay unambiguous.
  module Console
    READ_TIMEOUT = 300
    POLL = 0.5

    module_function

    def tools(read_timeout: READ_TIMEOUT, poll: POLL)
      [list_agents, read_agent(timeout: read_timeout, poll: poll), steer_agent, stop_agent]
    end

    def list_agents
      Tool.define(
        "list_agents",
        "See your workers: who is running, who finished, who was stopped. " \
        "Check here before spawning a duplicate."
      ) do |_args, context|
        children = context.session.children
        next "You have no workers." if children.empty?

        children.map do |child|
          "#{child.name} (#{child.session_id[0, 8]}): #{child.status}"
        end.join("\n")
      end
    end

    def read_agent(timeout: READ_TIMEOUT, poll: POLL)
      Tool.define(
        "read_agent",
        "Read what a worker has done so far without interrupting it, or pass " \
        "wait to block until it finishes and get its report.",
        schema: lambda {
          string :agent, "The worker's name or session id", required: true
          integer :tail, "How many recent entries to read (default 20)"
          boolean :wait, "Block until the worker finishes, then return its report"
        }
      ) do |args, context|
        child = Console.find(context.session, args["agent"])
        next Console.unknown(context.session, args["agent"]) unless child

        if args["wait"]
          Console.await(child, timeout, poll)
        else
          Console.render(child, args.fetch("tail", 20).to_i.clamp(1, 200))
        end
      end
    end

    def steer_agent
      Tool.define(
        "steer_agent",
        "Redirect or correct a running worker. It sees your message at its " \
        "next step; it may finish first. For a full restart, stop it and " \
        "spawn again with better instructions.",
        schema: lambda {
          string :agent, "The worker's name or session id", required: true
          string :message, "What the worker should know or do differently", required: true
        }
      ) do |args, context|
        child = Console.find(context.session, args["agent"])
        next Console.unknown(context.session, args["agent"]) unless child

        status = child.status
        if status == :running
          child.say(args.fetch("message"))
          "Queued. #{child.name} sees it at its next step; it may finish first."
        else
          "#{child.name} is #{status}, so there is nothing to steer. " \
            "Spawn a new worker for follow-up work."
        end
      end
    end

    def stop_agent
      Tool.define(
        "stop_agent",
        "Stop one worker. Its partial work is kept and its transcript stays " \
        "readable. Other workers and your own run continue.",
        schema: lambda {
          string :agent, "The worker's name or session id", required: true
        }
      ) do |args, context|
        child = Console.find(context.session, args["agent"])
        next Console.unknown(context.session, args["agent"]) unless child

        status = child.status
        if status != :running
          "#{child.name} is already #{status}."
        elsif child.stop
          "Stop requested. #{child.name} halts within a second or two; " \
            "its partial work stays readable through read_agent."
        else
          "Stopping needs a lock adapter (Mistri.locks) and none is configured."
        end
      end
    end

    # Latest spawn wins on duplicate names; ids and id prefixes (8+ chars)
    # stay unambiguous.
    def find(session, ref)
      children = session.children
      children.reverse_each.find { |child| child.name == ref } ||
        children.find do |child|
          child.session_id == ref || (ref.to_s.length >= 8 && child.session_id.start_with?(ref))
        end
    end

    def unknown(session, ref)
      names = session.children.map(&:name).uniq
      known = names.empty? ? "you have no workers" : "your workers: #{names.join(", ")}"
      "No worker matches #{ref.inspect}; #{known}."
    end

    def await(child, timeout, poll)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      while child.status == :running
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          return "#{child.name} is still running after #{timeout.round}s. " \
                 "Read it without wait to see progress, or stop it."
        end
        sleep poll
      end
      report = child.report
      "#{child.name} #{child.status}." + (report ? "\n#{report}" : "")
    end

    # A compact, readable transcript for a model: one line per entry, text
    # extracted, long values truncated. The gem never summarizes; the
    # caller can.
    def render(child, tail)
      entries = child.transcript(tail: tail)
      return "#{child.name} (#{child.status}): no entries yet." if entries.empty?

      lines = entries.map { |entry| Console.line(entry) }.compact
      "#{child.name} (#{child.status}), last #{lines.length} entries:\n#{lines.join("\n")}"
    end

    def line(entry)
      case entry["type"]
      when "message" then message_line(entry["message"] || {})
      when Child::TERMINAL
        ["#{entry["status"]}:", entry["report"] || entry["error"]].compact.join(" ")[0, 300]
      end
    end

    # Tool calls ride the message's content as typed blocks, never as a
    # separate key; render both channels from the blocks.
    def message_line(message)
      blocks = message["content"].is_a?(Array) ? message["content"] : []
      calls = blocks.filter_map do |block|
        next unless block.is_a?(Hash) && block["type"] == "tool_call"

        "#{block["name"]}(#{JSON.generate(block["arguments"] || {})[0, 80]})"
      end
      text = Console.text_of(message["content"])
      parts = [text[0, 240], *calls].reject { |part| part.to_s.empty? }
      "#{message["role"]}: #{parts.join(" | ")}" unless parts.empty?
    end

    def text_of(content)
      return content.to_s unless content.is_a?(Array)

      content.filter_map { |block| block["text"] if block.is_a?(Hash) }.join(" ")
    end
  end
end
