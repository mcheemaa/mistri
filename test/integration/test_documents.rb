# frozen_string_literal: true

require_relative "../support/integration"
require "monitor"

# The landing-page shape end to end: one DB-column-style document behind
# Workspace::Single, edited in place through the document tools.
class TestDocumentsIntegration < Minitest::Test
  Integration.scenario(self, :edits_a_single_document_headline) do |model|
    headline = Integration.codename
    document = +<<~HTML
      <header>
        <h1>Placeholder Headline</h1>
        <p class="tagline">Ship faster.</p>
      </header>
    HTML
    workspace = Mistri::Workspace::Single.new(read: -> { document.dup },
                                              write: ->(text) { document.replace(text) },
                                              path: "hero.html")
    agent = Mistri::Agent.new(provider: Mistri.provider(model),
                              tools: Mistri::Tools.files(workspace),
                              system: "Edit the page with the document tools. " \
                                      "Read before editing.")

    result = agent.run("Change the h1 headline to exactly: #{headline}")

    assert_predicate result, :completed?
    assert Integration.saw?(document, headline), "the document never changed"
    refute_includes document, "Placeholder Headline"
    assert_includes document, '<p class="tagline">Ship faster.</p>', "collateral damage"
  end

  Integration.scenario(self, :repairs_a_stale_document_edit) do |model|
    headline = Integration.codename
    document = +<<~HTML
      <main>
        <h1>Placeholder Headline</h1>
        <p>Keep this paragraph.</p>
      </main>
    HTML
    mutex = Mutex.new
    write = ->(text) { mutex.synchronize { document.replace(text) } }
    read_workspace = Mistri::Workspace::Single.new(
      path: "page.html",
      read: -> { mutex.synchronize { document.dup } },
      write:
    )
    first_edit = true
    edit_workspace = Mistri::Workspace::Single.new(
      path: "page.html",
      read: lambda {
        mutex.synchronize do
          if first_edit
            first_edit = false
            document.sub!("Placeholder Headline", "Concurrent human draft")
            document.sub!("</main>", "  <aside data-human=\"keep\">Preserve me.</aside>\n</main>")
          end
          document.dup
        end
      },
      write:
    )
    agent = Mistri::Agent.new(
      provider: Mistri.provider(model),
      tools: [Mistri::Tools.read_file(read_workspace), Mistri::Tools.edit_file(edit_workspace)],
      max_concurrency: 1,
      system: "Read page.html before editing it. Use edit_file, preserve every other element, " \
              "and recover from a stale edit by reading the current document."
    )

    result = agent.run("Change the h1 headline to exactly: #{headline}")

    assert_predicate result, :completed?
    assert(agent.session.messages.any? { |message| message.tool? && message.tool_error? },
           "the model never exercised the failed-edit repair path")
    assert Integration.saw?(document, headline), "the repaired edit never landed"
    assert_includes document, 'data-human="keep"', "the concurrent edit was overwritten"
    assert_includes document, "Keep this paragraph.", "unrelated content changed"
  end

  Integration.scenario(self, :rebases_an_unrelated_document_edit) do |model|
    headline = Integration.codename
    document = +<<~HTML
      <main>
        <h1>Placeholder Headline</h1>
        <p>Keep this paragraph.</p>
      </main>
    HTML
    monitor = Monitor.new
    injected = false
    workspace = Mistri::Workspace::Single.new(
      path: "page.html",
      read: -> { monitor.synchronize { document.dup } },
      write: ->(text) { monitor.synchronize { document.replace(text) } },
      synchronize: lambda { |&operation|
        monitor.synchronize do
          unless injected
            injected = true
            document.sub!("</main>", "  <aside data-human=\"keep\">Preserve me.</aside>\n</main>")
          end
          operation.call
        end
      }
    )
    agent = Mistri::Agent.new(
      provider: Mistri.provider(model),
      tools: [Mistri::Tools.read_file(workspace), Mistri::Tools.edit_file(workspace)],
      max_concurrency: 1,
      system: "Read page.html before editing it. Change only the requested headline and " \
              "preserve every other element."
    )

    result = agent.run("Change the h1 headline to exactly: #{headline}")

    assert_predicate result, :completed?
    refute(agent.session.messages.any? { |message| message.tool? && message.tool_error? },
           "the internal storage retry leaked out as a failed tool call")
    assert Integration.saw?(document, headline), "the rebased edit never landed"
    assert_includes document, 'data-human="keep"', "the concurrent edit was overwritten"
    assert_includes document, "Keep this paragraph.", "unrelated content changed"
  end
end
