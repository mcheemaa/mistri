# frozen_string_literal: true

module Mistri
  # Provider-executed web search. Passed alongside tools, it lets the model
  # search the web while it answers; the provider runs the search on its own
  # side, so the loop never executes anything and no results cross the
  # tool-result boundary. What the search did arrives as server-tool content
  # blocks on the assistant message.
  class WebSearch
    def name = "web_search"
  end

  class << self
    # The value is stateless, so one frozen instance serves every agent.
    #
    #   agent = Mistri.agent("claude-opus-4-8", tools: [Mistri.web_search])
    def web_search
      @web_search ||= WebSearch.new.freeze
    end
  end
end
