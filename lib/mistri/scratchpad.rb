# frozen_string_literal: true

require "securerandom"

module Mistri
  # The agent's own folder in a workspace the host builds and scopes, where
  # the whole of a tool result that is too large to show is saved.
  class Scratchpad
    ROOT = "scratchpad/"
    RESULTS = "scratchpad/tool-results/"
    MAX_LISTING_BYTES = 4_000
    NOTE = "You have a scratchpad: documents under scratchpad/ for your own work. A " \
           "tool result that is too large to show is saved whole under " \
           "scratchpad/tool-results/, and only its start is shown to you. Read such a " \
           "document in parts with read_file, or search it with grep, instead of calling " \
           "the tool again. You may keep notes of your own under scratchpad/."
    SHARED = "Other agents share this scratchpad. Write what you find under %<folder>s as " \
             "you go, in documents with plain names, and name them in your report: the " \
             "agent that started you reads them there."
    private_constant :MAX_LISTING_BYTES, :NOTE, :SHARED

    attr_reader :workspace

    def initialize(workspace, worker_folder: nil)
      @workspace = workspace
      @worker_folder = worker_folder
      @atomic = Tools.atomic_workspace?(workspace)
    end

    def for_worker(name)
      part = name.to_s.downcase.gsub(/[^a-z0-9]+/, "-").delete_prefix("-").delete_suffix("-")
      self.class.new(@workspace, worker_folder: "#{ROOT}agents/#{part}/")
    end

    # The name ends in random characters, so agents that share a scratchpad
    # with no conditional write never pick one name.
    def save_result(text, tool_name)
      path = "#{RESULTS}#{named(tool_name)}.#{json?(text) ? "json" : "txt"}"
      create(path, text) || raise(Error, "#{path} is taken")
    end

    # Bytes a tool was handed that are no text, kept whole beside the results.
    # extension starts with its dot. A workspace that holds only text raises.
    def save_binary(bytes, tool_name, extension = ".bin")
      path = "#{RESULTS}#{named(tool_name)}#{extension}"
      create(path, bytes.b) || raise(Error, "#{path} is taken")
    end

    # After a compaction the earlier note is gone from the conversation, so the
    # note also lists what the scratchpad holds.
    def note
      text = @worker_folder ? "#{NOTE} #{format(SHARED, folder: @worker_folder)}" : NOTE
      held = listing
      held.empty? ? text : "#{text}\n\nIt holds:\n#{held}"
    end

    private

    def named(tool_name)
      "#{Time.now.utc.strftime("%Y%m%dT%H%M%S")}-" \
        "#{tool_name.to_s.gsub(/[^A-Za-z0-9_-]/, "_")}-#{SecureRandom.hex(4)}"
    end

    def create(path, text)
      return create_in_two_steps(path, text) unless @atomic

      @workspace.compare_and_write(path, text, expected_revision: nil)
      path
    rescue WorkspaceConflictError
      nil
    rescue ConfigurationError
      create_in_two_steps(path, text)
    end

    def create_in_two_steps(path, text)
      return if @workspace.read(path)

      @workspace.write(path, text)
      path
    end

    # Judged by its two ends, because parsing a large result to name its
    # document costs more than saving it.
    def json?(text)
      closing = { "{" => "}", "[" => "]" }[text[0]]
      return false unless closing

      (text.byteslice(-64..) || text).b.rstrip.end_with?(closing)
    end

    def listing
      lines = if @workspace.respond_to?(:sizes)
                @workspace.sizes(ROOT).map { |path, bytes| "#{path} (#{bytes} bytes)" }
              else
                @workspace.list(ROOT)
              end
      shown = []
      lines.each do |line|
        break if shown.sum(&:bytesize) + line.bytesize > MAX_LISTING_BYTES

        shown << line
      end
      more = lines.length - shown.length
      more.positive? ? [*shown, "[#{more} more. Use list_files.]"].join("\n") : shown.join("\n")
    end
  end
end
