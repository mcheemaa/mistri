# frozen_string_literal: true

# Give an agent a real browser in one line: Playwright's official MCP
# server over the stdio wire. The allowlist grants only what this agent
# needs, and needs_approval gates could ride any of it. Needs
# ANTHROPIC_API_KEY, node, and Chrome.
#
#   ruby examples/browser.rb

require "mistri"

browser = Mistri::MCP::Client.new(
  command: ["npx", "-y", "@playwright/mcp@latest", "--browser", "chrome", "--headless"],
  read_timeout: 180
)

begin
  tools = Mistri::MCP.tools(browser, prefix: "web",
                                     allow: %w[browser_navigate browser_snapshot])

  agent = Mistri.agent("claude-opus-4-8", tools: tools,
                                          system: "Use the browser tools to answer. Be brief.")

  puts agent.run("Open https://example.com and report the main heading.").text
ensure
  browser.close
end
