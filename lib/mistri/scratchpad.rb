# frozen_string_literal: true

module Mistri
  # The agent's own folder in a workspace the host builds and scopes, where
  # the whole of a tool result that is too large to show is saved.
  class Scratchpad
    ROOT = "scratchpad/"
    RESULTS = "scratchpad/tool-results/"
    MAX_NAMES = 5
    MAX_LISTING_BYTES = 4_000
    NOTE = "You have a scratchpad: documents under scratchpad/ for your own work. A " \
           "tool result that is too large to show is saved whole under " \
           "scratchpad/tool-results/, and only its start is shown to you. Read such a " \
           "document in parts with read_file, or search it with grep, instead of calling " \
           "the tool again. You may keep notes of your own under scratchpad/."
    SHARED = "Other agents share this scratchpad. Write what you find under %<folder>s as " \
             "you go, in documents with plain names, and name them in your report: the " \
             "agent that started you reads them there."
    private_constant :MAX_NAMES, :MAX_LISTING_BYTES, :NOTE, :SHARED

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

    # A name that is taken gets a number, so a result never replaces another.
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

    # After a compaction the earlier note is gone from the conversation, so the
    # note also lists what the scratchpad holds.
    def note
      text = @worker_folder ? "#{NOTE} #{format(SHARED, folder: @worker_folder)}" : NOTE
      held = listing
      held.empty? ? text : "#{text}\n\nIt holds:\n#{held}"
    end

    private

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
