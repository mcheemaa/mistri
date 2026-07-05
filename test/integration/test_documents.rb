# frozen_string_literal: true

require_relative "../support/integration"

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
end
