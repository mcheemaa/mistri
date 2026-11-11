# frozen_string_literal: true

require_relative "test_helper"

# The search ranks tools by their name, their description and the names and
# descriptions of their parameters.
class TestToolSearchRanking < Minitest::Test
  def tool(name, description = "", schema: nil)
    Mistri::Tool.define(name, description, schema:) { "ran" }
  end

  def rank(query, tools, limit = 8) = Mistri::ToolSearch.rank(query, tools, limit).map(&:name)

  def test_a_word_in_the_name_beats_any_number_of_mentions_in_the_description
    tools = [tool("list_pages", "Issue issue issue: pages that mention an issue."),
             tool("create_issue", "Opens a ticket.")]

    assert_equal %w[create_issue list_pages], rank("issue", tools)
  end

  def test_a_tool_that_matches_more_of_the_query_comes_first
    tools = [tool("window", "A window."),
             tool("capture", "Takes a screenshot of one window of the desktop.")]

    assert_equal %w[capture window], rank("screenshot window", tools)
  end

  def test_a_query_that_is_a_tool_name_finds_that_tool_first
    tools = [tool("tracker__read_thread", "Read a thread. Thread read, thread read, read thread."),
             tool("tracker__thread_read", "Opens one.")]

    assert_equal "tracker__thread_read", rank("thread_read", tools).first
    assert_equal "tracker__thread_read", rank("tracker__thread_read", tools).first
    assert_equal "tracker__thread_read", rank("Thread-Read", tools).first
    assert_equal "tracker__read_thread", rank("read thread", tools).first
  end

  def test_a_tool_is_found_by_its_exact_name_whatever_the_name_is
    tools = [tool("at", "Schedules a command."), tool("_", "Repeats the last command."),
             tool("other", "At the end of the day it does nothing.")]

    assert_equal %w[at], rank("at", tools)
    assert_equal %w[_], rank("_", tools)
  end

  def test_the_literal_name_comes_before_names_that_only_read_alike
    alike = %w[get-open-pull-request-status get_open-pull-request-status
               get-open_pull-request-status get_open_pull-request-status
               get-open-pull_request-status get_open-pull_request-status
               get-open_pull_request-status get_open_pull_request-status
               get-open-pull-request_status get_open_pull_request_status]
    tools = alike.map { |name| tool(name, "Reads the status.") }

    assert_equal "get_open_pull_request_status", rank("get_open_pull_request_status", tools).first
    assert_equal "tracker__list",
                 rank("list", [tool("docs__list-all"), tool("tracker__list")]).first
    assert_equal "b__get_status",
                 rank("get_status", [tool("a__get-status"), tool("b__get_status")]).first
    assert_equal 8, rank("get_open_pull_request_status", tools).length
  end

  def test_text_written_without_spaces_is_matched_by_pairs_of_characters
    search = tool("docs__search", "搜索团队文档并返回结果")
    other = tool("docs__delete", "删除一个页面")

    assert_equal %w[docs__search], rank("搜索文档", [other, search])
    assert_equal %w[docs__delete], rank("删除页面", [other, search])
    assert_equal %w[notes__find], rank("ノート", [tool("notes__find", "ノートを検索します"), other])
  end

  def test_text_that_cannot_be_a_name_never_counts_as_one
    odd = Array.new(8) { |index| tool("misc#{index}____", "Manages settings.") }
    search = tool("docs__search", "検索して文書を見つける")

    assert_equal %w[docs__search], rank("検索", [*odd, search])
    assert_empty rank("!!", [tool("thing____", "A thing.")])
    assert_empty rank("- .", [tool("thing____", "A thing.")])
    settings = tool("pdf__", "Manage settings")

    assert_equal "docs__find", rank("PDF文档", [settings, tool("docs__find", "PDF文档搜索")]).first
    assert_equal %w[Thread-Read], rank("thread_read", [tool("Thread-Read", "Opens one.")])
  end

  def test_punctuation_between_kana_separates_and_is_not_searched
    export = tool("export", "レコード・エクスポート")

    assert_empty rank("・", [export, tool("dump", "Exports ・ records")])
    assert_equal %w[export], rank("レコード", [export])
    assert_equal %w[export], rank("エクスポート", [export])
    assert_equal %w[notes], rank("ノート", [tool("food", "トマトノルマ"), tool("notes", "ノートを検索")])
  end

  def test_one_character_finds_a_run_that_holds_it
    pets = tool("pets__find", "猫の情報を検索")
    other = tool("docs__find", "文書を検索")

    assert_equal %w[pets__find], rank("猫", [other, pets])
    assert_equal %w[docs__find], rank("文書", [other, pets])
  end

  def test_single_characters_do_not_make_a_description_count_as_longer
    pages = Array.new(8) do |index|
      tool("docs__page_#{index}", "Explains the refund policy and documents account " \
                                  "credits, receipts, taxes and billing adjustments.")
    end
    apply = tool("billing__apply", "refund 顧客へ返金する")

    assert_equal "billing__apply", rank("refund", [*pages, apply]).first
  end

  def test_one_character_finds_a_name_that_holds_it
    assert_equal %w[猫検索], rank("猫", [tool("猫検索", ""), tool("other", "Nothing.")])
  end

  def test_text_in_another_width_or_form_matches_its_usual_form
    notes = tool("notes", "ノートを検索します")
    guide = tool("guide", "ガイドを開く")

    assert_equal %w[notes], rank("ﾉｰﾄ", [guide, notes])
    assert_equal %w[guide], rank("カ\u3099イド", [notes, guide])
    assert_equal %w[notes], rank("ノート", [tool("notes", "ﾉｰﾄを検索します"), guide])
    assert_equal %w[wide], rank("ｐｄｆ", [tool("wide", "Reads a PDF."), guide])
  end

  def test_words_and_text_without_spaces_can_sit_side_by_side
    mixed = tool("docs__find", "PDF文档搜索")
    other = tool("docs__delete", "删除一个页面")

    assert_equal %w[docs__find], rank("pdf", [other, mixed])
    assert_equal %w[docs__find], rank("文档", [other, mixed])
  end

  def test_names_split_at_underscores_hyphens_and_capitals
    tools = [tool("createIssue"), tool("delete-project"), tool("list_teams"), tool("getPRDiff")]

    assert_equal %w[createIssue], rank("issue", tools)
    assert_equal %w[delete-project], rank("project", tools)
    assert_equal %w[list_teams], rank("teams", tools)
    assert_equal %w[getPRDiff], rank("diff", tools)
    assert_equal %w[getPRDiff], rank("pr", tools)
  end

  def test_a_plural_finds_the_singular_and_the_other_way_round
    tools = [tool("create_issue"), tool("list_categories"), tool("search_boxes")]

    assert_equal %w[create_issue], rank("issues", tools)
    assert_equal %w[list_categories], rank("category", tools)
    assert_equal %w[search_boxes], rank("box", tools)
  end

  def test_parameter_names_and_their_descriptions_are_searched
    by_name = tool("export", "Writes a file.", schema: -> { string :invoice, "The id." })
    by_text = tool("send", "Sends it.", schema: -> { string :to, "The customer's mailbox." })

    assert_equal %w[export], rank("invoice", [by_name, by_text])
    assert_equal %w[send], rank("mailbox", [by_name, by_text])
  end

  def test_parameters_nested_in_objects_and_arrays_are_searched
    nested = tool("update", "Changes a record.", schema: lambda {
      object(:address, "Where it goes") { string :postcode, "The postal code." }
      array :labels, "Tags to set", items: { type: "string", description: "A colour name." }
    })

    assert_equal %w[update], rank("postcode", [nested, tool("other", "Nothing.")])
    assert_equal %w[update], rank("colour", [nested, tool("other", "Nothing.")])
  end

  def test_alternatives_and_shared_definitions_are_searched
    pager = { "type" => "string", "description" => "A pager number." }
    mailbox = { "type" => "object", "properties" => { "inbox" => { "type" => "string" } } }
    target = { "anyOf" => [{ "$ref" => "#/$defs/mailbox" }, pager] }
    schema = { "type" => "object", "$defs" => { "mailbox" => mailbox },
               "properties" => { "target" => target } }
    notify = Mistri::Tool.define("notify", "Tells someone.", input_schema: schema) { "ran" }

    assert_equal %w[notify], rank("pager", [notify, tool("other", "Nothing.")])
    assert_equal %w[notify], rank("inbox", [notify, tool("other", "Nothing.")])
  end

  def test_common_words_do_not_match_anything
    tools = [tool("create_issue", "Creates the issue for a project.")]

    assert_empty rank("the for a", tools)
    assert_empty rank("   ", tools)
  end

  def test_no_more_than_the_limit_come_back_and_equal_matches_keep_their_order
    tools = %w[b a d c].map { |name| tool("#{name}__get_issue", "Reads an issue.") }

    assert_equal %w[b__get_issue a__get_issue], rank("issue", tools, 2)
    assert_empty rank("issue", tools, 0)
  end

  def test_a_tool_whose_whole_name_is_in_the_query_beats_one_with_more_in_its_name
    tools = [tool("dock__list_apps", "Shows them."), tool("dock__app", "Opens it.")]

    assert_equal %w[dock__app dock__list_apps], rank("dock app", tools)
  end

  def test_one_mention_in_a_short_description_beats_one_in_a_long_description
    long = tool("keep", "Puts a record in the archive. #{"It leaves the history as it was. " * 80}")
    short = tool("stow", "Puts a record in the archive.")

    assert_equal %w[stow keep], rank("archive", [long, short])
  end
end
