# frozen_string_literal: true

module Mistri
  module Tools
    MAX_CODE_RESULT_BYTES = 10_000
    MAX_WRITTEN_BYTES = 5_000_000
    RUN_CODE = "Run JavaScript on your documents and tools. The code is the body of an async " \
               "function, so await and return work. Only what the code returns, and what it " \
               "prints with console.log, comes back to you. Use it to search, count, sort, add " \
               "up or join data without reading the data into the conversation. In the code: " \
               "files.read(path) returns the whole text of a document as a string; " \
               "files.write(path, text) writes one; files.list(prefix) returns the paths under " \
               "a folder; files.delete(path) deletes one. A write replaces a document only " \
               "if your code has read or written it, in this call or an earlier one, and it " \
               "has not changed since. await tools.NAME(arguments) calls " \
               "one of your other tools with the arguments it takes and returns its result as " \
               "a string, or throws an error when the tool fails. Standard JavaScript is there " \
               "(JSON, RegExp, Math, Date, Map, Set). There is no network, no Node.js, no " \
               "require, no timers and no URL class. Return only what you need to " \
               "read%<limit>s. Write a longer output to a document with files.write and return " \
               "its path."
    private_constant :RUN_CODE

    # What one run of code has done so far: the versions of the documents it
    # and the runs before it read or wrote, the bytes it wrote and the calls
    # it made.
    CodeRun = Struct.new(:seen, :written, :calls)
    private_constant :CodeRun

    module_function

    def run_code(sandbox, limited: true, &host)
      limit = ": a result over #{MAX_CODE_RESULT_BYTES} bytes is cut" if limited
      Tool.define("run_code", format(RUN_CODE, limit:),
                  result_limit: MAX_CODE_RESULT_BYTES,
                  schema: lambda {
                    string :code, "JavaScript, the body of an async function", required: true
                  }) do |args, context|
        remembering(context&.session) do |run|
          asked = ->(operation, payload) { host.call(operation, payload, context, run) }
          code_result(sandbox.run(args["code"].to_s, host: asked))
        end
      rescue Error => e
        ToolResult.new(content: "The code did not finish: #{e.message}", error: true)
      end
    end

    # A run starts from the versions the session holds and leaves the ones it
    # learned there, also when the code fails or is stopped.
    def remembering(session)
      known = session ? session.code_documents : {}
      run = CodeRun.new(known.dup, 0, 0)
      begin
        yield run
      ensure
        learned = run.seen.reject { |path, version| known[path] == version }
        session&.remember_code_documents(learned.to_a)
      end
    end

    def code_result(outcome)
      parts = outcome.output.dup
      if outcome.error
        parts << "The code failed:\n#{outcome.error}"
      elsif !outcome.value.nil?
        parts << (outcome.value.is_a?(String) ? outcome.value : JSON.generate(outcome.value))
      end
      text = parts.empty? ? "(the code returned nothing and printed nothing)" : parts.join("\n")
      outcome.error ? ToolResult.new(content: text, error: true) : text
    end

    def file_from_code(workspace, operation, payload, run)
      path = (operation == "list" ? payload["prefix"] : payload["path"]).to_s
      everything = operation == "list" && path.empty?
      unusable = unusable_path(path, prefix: operation == "list") unless everything
      raise Error, unusable.content if unusable

      case operation
      when "read" then read_from_code(workspace, path, run.seen)
      when "list"
        paths = workspace.list(payload["prefix"])
        [paths, paths.join("\n")]
      when "write" then write_from_code(workspace, path, payload["content"].to_s, run)
      when "delete" then delete_from_code(workspace, path)
      end
    end

    def read_from_code(workspace, path, seen)
      content = workspace.read(path)
      raise Error, "No document at #{path.inspect}" if content.nil?
      raise Error, "#{path} is not text, so code cannot read it" unless content.valid_encoding?

      remember(seen, path, content) unless read_only(path)
      [content, "Read #{path} (#{content.bytesize} bytes)"]
    end

    # The newest last, so a table that is full gives up its oldest.
    def remember(seen, path, content)
      seen.delete(path)
      seen[path] = version(content)
    end

    # The version code last read or wrote stands in for if_version, so a write
    # from code is conditional wherever write_file's is.
    def write_from_code(workspace, path, content, run)
      refuse_read_only(path)
      refuse_over_budget(run, content.bytesize)
      seen = run.seen
      written = if atomic_workspace?(workspace)
                  write_atomically(workspace, path, content, seen[path])
                else
                  write_legacy(workspace, path, content, seen[path])
                end
      if written.is_a?(StaleWrite)
        raise Error, "#{path} holds a document your code has not read or written, or one " \
                     "that changed since. Nothing was written. Read it with files.read, " \
                     "then write it."
      end

      run.written += written.bytesize
      remember(seen, path, written)
      [nil, "Wrote #{path} (#{written.length} chars), version #{seen[path]}"]
    end

    # A model's own write is bounded by what it can write in a turn. Code is
    # bounded only by the clock, so one run has a budget.
    def refuse_over_budget(run, bytes)
      return if run.written + bytes <= MAX_WRITTEN_BYTES

      raise Error, "One run of code writes #{MAX_WRITTEN_BYTES} bytes at most, and this " \
                   "write would pass that. Write the rest in another run_code call."
    end

    # tools.write_file in code writes where files.write does, so it counts
    # against the same budget.
    def within_budget(run, tool, arguments)
      built_in = tool.name == "write_file" && bound_workspace(tool)
      bytes = built_in ? arguments["content"].to_s.bytesize : 0
      refuse_over_budget(run, bytes)
      result = yield
      run.written += bytes unless result.is_a?(ToolResult) && result.error?
      result
    end

    def delete_from_code(workspace, path)
      refuse_read_only(path)
      raise Error, "No document at #{path.inspect}" if workspace.read(path).nil?

      workspace.delete(path)
      [nil, "Deleted #{path}"]
    end

    def refuse_read_only(path)
      refusal = read_only(path)
      raise Error, refusal.content if refusal
    end

    private_class_method :code_result, :read_from_code, :write_from_code, :delete_from_code,
                         :refuse_read_only, :refuse_over_budget, :remember, :remembering
  end
end
