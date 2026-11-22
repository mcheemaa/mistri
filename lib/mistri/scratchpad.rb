# frozen_string_literal: true

module Mistri
  # The agent's own folder in a workspace the host builds and scopes. The whole
  # of a tool result that is too large to show is saved under
  # scratchpad/tool-results/, and the model reads it there in parts with the
  # document tools.
  #
  #   Mistri.agent("claude-opus-5-5", tools: tools, scratchpad: workspace)
  class Scratchpad
    ROOT = "scratchpad/"
    RESULTS = "scratchpad/tool-results/"
    MAX_NAMES = 5
    MAX_LISTING_BYTES = 4_000
    NOTE = "You have a scratchpad: documents under scratchpad/ that only you read and " \
           "write. A tool result that is too large to show is saved whole under " \
           "scratchpad/tool-results/, and only its start is shown to you. Read such a " \
           "document in parts with read_file, or search it with grep, instead of calling " \
           "the tool again. You may keep notes of your own under scratchpad/."
    private_constant :MAX_NAMES, :MAX_LISTING_BYTES, :NOTE

    attr_reader :workspace

    def initialize(workspace)
      @workspace = workspace
      @atomic = Tools.atomic_workspace?(workspace)
    end

    # Saves the whole text of one result and returns its path. A name that is
    # taken gets a number, so a result never replaces another.
    def save_result(text, tool_name)
      stem = "#{RESULTS}#{Time.now.utc.strftime("%Y%m%dT%H%M%S")}-" \
             "#{tool_name.to_s.gsub(/[^A-Za-z0-9_-]/, "_")}"
      extension = json?(text) ? "json" : "txt"
      MAX_NAMES.times do |attempt|
        path = create("#{stem}#{"-#{attempt + 1}" if attempt.positive?}.#{extension}", text)
        return path if path
      end
      raise Error, "no free name for a saved result at #{stem}.#{extension}"
    end

    # What the model is told about the scratchpad. After a compaction the
    # earlier note is gone from the conversation, so this one also lists what
    # the scratchpad holds.
    def note
      held = listing
      held.empty? ? NOTE : "#{NOTE}\n\nIt holds:\n#{held}"
    end

    private

    # The path, or nil when a document is there already.
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

    def json?(text)
      return false unless text.start_with?("{", "[")

      JSON.parse(text)
      true
    rescue JSON::ParserError
      false
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
