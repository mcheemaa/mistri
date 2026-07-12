# frozen_string_literal: true

# The landing-page shape: one value (a database column in production, a
# string here) edited in place through the document tools. A host can wrap the
# result in ToolResult when it also needs a separate UI payload.
# Needs ANTHROPIC_API_KEY.
#
#   ruby examples/page_editor.rb

require "mistri"

page = +<<~HTML
  <header>
    <h1>Placeholder Headline</h1>
    <p class="tagline">Ship faster.</p>
  </header>
HTML

workspace = Mistri::Workspace::Single.new(
  read: -> { page.dup },
  write: ->(html) { page.replace(html) },
  path: "hero.html"
)

agent = Mistri.agent("claude-opus-4-8",
                     tools: Mistri::Tools.files(workspace),
                     system: "Edit the page with the document tools. Read before editing.")

agent.run("Change the h1 headline to: Gifts that land.")

puts page
