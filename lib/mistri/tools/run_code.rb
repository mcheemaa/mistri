# frozen_string_literal: true

module Mistri
  module Tools
    MAX_CODE_RESULT_BYTES = 10_000
    RUN_CODE = "Run JavaScript on your documents and tools. The code is the body of an async " \
               "function, so await and return work. Only what the code returns, and what it " \
               "prints with console.log, comes back to you. Use it to search, count, sort, add " \
               "up or join data without reading the data into the conversation. In the code: " \
               "files.read(path) returns the whole text of a document as a string; " \
               "files.write(path, text) writes one; files.list(prefix) returns the paths under " \
               "a folder; files.delete(path) deletes one. await tools.NAME(arguments) calls " \
               "one of your other tools with the arguments it takes and returns its result as " \
               "a string, or throws an error when the tool fails. Standard JavaScript is there " \
               "(JSON, RegExp, Math, Date, Map, Set). There is no network, no Node.js, no " \
               "require, no timers and no URL class. Return only what you need to " \
               "read%<limit>s. Write a longer output to a document with files.write and return " \
               "its path."
    private_constant :RUN_CODE

    module_function

    def run_code(sandbox, limited: true, &host)
      limit = ": a result over #{MAX_CODE_RESULT_BYTES} bytes is cut" if limited
      Tool.define("run_code", format(RUN_CODE, limit:),
                  result_limit: MAX_CODE_RESULT_BYTES,
                  schema: lambda {
                    string :code, "JavaScript, the body of an async function", required: true
                  }) do |args, context|
        run = {}
        asked = ->(operation, payload) { host.call(operation, payload, context, run) }
        code_result(sandbox.run(args["code"].to_s, host: asked))
      rescue Error => e
        ToolResult.new(content: "The code did not finish: #{e.message}", error: true)
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

    def file_from_code(workspace, operation, payload, seen)
      path = (operation == "list" ? payload["prefix"] : payload["path"]).to_s
      everything = operation == "list" && path.empty?
      unusable = unusable_path(path, prefix: operation == "list") unless everything
      raise Error, unusable.content if unusable

      case operation
      when "read" then read_from_code(workspace, path, seen)
      when "list"
        paths = workspace.list(payload["prefix"])
        [paths, paths.join("\n")]
      when "write" then write_from_code(workspace, path, payload["content"].to_s, seen)
      when "delete" then delete_from_code(workspace, path)
      end
    end

    def read_from_code(workspace, path, seen)
      content = workspace.read(path)
      raise Error, "No document at #{path.inspect}" if content.nil?

      seen[path] = version(content)
      [content, "Read #{path} (#{content.bytesize} bytes)"]
    end

    # The version this run read stands in for if_version, so a write from code
    # is conditional wherever write_file's is.
    def write_from_code(workspace, path, content, seen)
      refuse_read_only(path)
      written = if atomic_workspace?(workspace)
                  write_atomically(workspace, path, content, seen[path])
                else
                  write_legacy(workspace, path, content, seen[path])
                end
      if written.is_a?(StaleWrite)
        raise Error, "#{path} holds a document this code has not read, or one that changed " \
                     "since. Read it in this code before writing it."
      end

      seen[path] = version(written)
      [nil, "Wrote #{path} (#{written.length} chars), version #{seen[path]}"]
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
                         :refuse_read_only
  end
end
