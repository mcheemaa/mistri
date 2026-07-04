# frozen_string_literal: true

module Mistri
  # Loads skills and wires them into an agent: their one-line descriptions
  # ride the system prompt, and the model pulls a full body on demand with
  # the read_skill tool — so a large library costs almost nothing until a
  # skill is actually used.
  module Skills
    module_function

    # Reads a directory of skills in either layout: <dir>/<name>/SKILL.md
    # or <dir>/<name>.md. Frontmatter (name:, description:) overrides the
    # path-derived name.
    def load(path)
      raise ConfigurationError, "no skills directory at #{path}" unless File.directory?(path)

      skills = Dir.children(path).sort.filter_map do |child|
        full = File.join(path, child)
        if File.directory?(full) && File.file?(File.join(full, "SKILL.md"))
          read(File.join(full, "SKILL.md"), default_name: child)
        elsif child.end_with?(".md") && File.file?(full)
          read(full, default_name: File.basename(child, ".md"))
        end
      end
      skills.sort_by(&:name)
    end

    def read(file, default_name:)
      meta, body = parse(File.read(file))
      Skill.new(name: meta.fetch("name", default_name),
                description: meta.fetch("description", ""), body: body)
    end

    # The always-present cost of a skill library: one line per skill.
    def section(skills)
      lines = skills.map { |skill| "- #{skill.name}: #{skill.description}" }
      <<~TEXT.strip
        ## Skills

        Expert playbooks. When one matches the task, call read_skill with its
        name and follow it before acting.

        #{lines.join("\n")}
      TEXT
    end

    def amend(system, skills)
      return system if skills.empty?

      [system, section(skills)].compact.join("\n\n")
    end

    def reader(skills)
      by_name = skills.to_h { |skill| [skill.name, skill] }
      Tool.define("read_skill", "Reads the full playbook for a named skill.",
                  schema: -> { string :name, "Skill name", required: true }) do |args|
        skill = by_name[args["name"]]
        next skill.body if skill

        "Unknown skill #{args["name"].inspect}. Available: #{by_name.keys.join(", ")}"
      end
    end

    # Frontmatter is deliberately a subset: flat string keys between ---
    # markers, quotes optional. name and description are the whole contract,
    # and a YAML dependency is not worth two fields.
    def parse(text)
      return [{}, text] unless text.start_with?("---\n")

      head, separator, body = text[4..].partition("\n---\n")
      return [{}, text] if separator.empty?

      meta = {}
      head.scan(/^([a-z_]+):[ \t]*(.+?)[ \t]*$/) do |key, value|
        meta[key] = value.gsub(/\A["']|["']\z/, "")
      end
      [meta, body.sub(/\A\n+/, "")]
    end
  end
end
