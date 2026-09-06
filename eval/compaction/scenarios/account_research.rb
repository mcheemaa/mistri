# frozen_string_literal: true

# A sales assistant chat: a Shopify Plus account executive researching a
# merchant prospect before a gift send. Names and addresses from tool JSON,
# preferences, a do-not-contact rule, a budget and a deadline that both move,
# and a gift decision with a policy behind it. Every person, address, and
# number is invented; the prospect is a real merchant used only as a name.
CompactionEval::Scenario.define("account_research",
                                summary: "Merchant research for a gift send") do
  filler do |turn, rng|
    page = turn + 1
    shapes = [
      { ask: "Keep going: pull page #{page} of the account's recent activity and note " \
             "anything that changes who we should send to or what we should say.",
        doing: "Fetching page #{page} of recent activity and scanning it for role changes, " \
               "new stakeholders, and timing signals.",
        tool: "fetch_activity",
        arguments: { "account" => "allbirds", "page" => page },
        log: CompactionEval::Filler.activity_json(rng),
        done: "Page #{page} adds nothing that changes the plan: same stakeholders, no new " \
              "timing signal." },
      { ask: "Next: look up the account's open support tickets and see whether anything " \
             "there should shape the note.",
        doing: "Listing open support tickets for the account, newest first.",
        tool: "list_tickets",
        arguments: { "account" => "allbirds", "status" => "open" },
        log: CompactionEval::Filler.tickets_json(rng),
        done: "Nothing in support that should colour the note; the open tickets are routine " \
              "theme and app questions." },
      { ask: "Next: check recent news mentions for the account so we do not step on anything.",
        doing: "Searching recent news mentions for the account and skimming the headlines.",
        tool: "search_news",
        arguments: { "query" => "Allbirds", "days" => 30 },
        log: CompactionEval::Filler.news_json(rng),
        done: "Nothing sensitive in the news window. Reasoning it through: the mentions are " \
              "product launches and a sustainability report, none of it something a gift " \
              "note should reference, so the note stays personal and short." },
      { ask: "Next: what did the last three touches from our side look like, and who sent " \
             "them?",
        doing: "Reading the last three outbound touches on the account.",
        tool: "fetch_touches",
        arguments: { "account" => "allbirds", "limit" => 3 },
        log: CompactionEval::Filler.touches_json(rng),
        done: "The last touches were routine check-ins from the account team; no gift has " \
              "gone out this quarter, so the send is not a repeat." }
    ]
    CompactionEval::Filler.turn(turn, rng, shapes)
  end

  segment do
    fact :company, "Allbirds",
         at: 0.0,
         text: "Research %<value>s for a gift send to their marketing leadership.",
         probe: "Which merchant are we researching? Reply with the company name only."
    fact :campaign, "CMP-8842",
         at: 0.0,
         text: "This is for campaign %<value>s.",
         probe: "Which campaign id is this send for? Reply with the id only."
    fact :contact, "Dana Whitfield",
         at: 0.05, carrier: :tool,
         text: '{"contact":{"name":"%<value>s","title":"VP Marketing","seniority":"vp"}}',
         probe: "Who is the target contact? Reply with the full name only."
    fact :email, "dana.whitfield@allbirds.example",
         at: 0.05, carrier: :tool,
         text: '{"contact_email":"%<value>s","verified":true}',
         probe: "What is the target contact's email address? Reply with the address only."
    fact :do_not_contact, "no",
         at: 0.1, match: :yes_no,
         text: "Lars Berg is on their do-not-contact list; never include him.",
         probe: "May you include Lars Berg in the send? Answer yes or no."
    fact :tone, "no",
         at: 0.12, match: :yes_no,
         text: "Tone is warm and plain: no exclamation marks anywhere in the note.",
         probe: "Are exclamation marks allowed in the note? Answer yes or no."
    fact :budget, "$75",
         at: 0.15,
         text: "Budget is %<value>s per gift.",
         probe: "What is the budget per gift now? Reply with the amount only."
    fact :deadline, "October 14",
         at: 0.2,
         text: "It must land before their Q4 kickoff on %<value>s.",
         probe: "By what date must the gift land now? Reply with the date only."
    fact :address, "730 Montgomery St, Suite 400, San Francisco, CA 94111",
         at: 0.3, carrier: :tool, answer: "730 Montgomery St",
         text: '{"office":{"address":"%<value>s","type":"hq"}}',
         probe: "What is the shipping address? Reply with the street address only."
    fact :opportunity, "006Qx000004Uy",
         at: 0.35, carrier: :tool,
         text: '{"salesforce_opportunity":"%<value>s","stage":"Evaluation"}',
         probe: "What is the Salesforce opportunity id? Reply with the id only."
    fact :competitor, "no",
         at: 0.4, match: :yes_no,
         text: "They evaluated BigCommerce last quarter; do not mention BigCommerce in the note.",
         probe: "May the note mention BigCommerce? Answer yes or no."
    fact :hobby, "trail running",
         at: 0.5, carrier: :tool_deep,
         text: '{"bio_note":"weekends are for %<value>s and the occasional half marathon"}',
         probe: "What hobby did the profile mention? Reply with the hobby only."
    fact :item, "notebook bundle",
         at: 0.6, carrier: :assistant,
         text: "Decision: send the %<value>s, not the whiskey, because their gift policy " \
               "excludes alcohol.",
         probe: "Which item did we decide to send? Reply with the item only."
    fact :policy, "alcohol",
         at: 0.6, carrier: :assistant,
         text: "Their policy note says gifts containing %<value>s are returned unopened.",
         probe: "What does their gift policy exclude? Reply with one word."
    change :budget, "$60",
           at: 0.7,
           text: "Finance trimmed the budget to %<value>s per gift."
    fact :sender, "Rowan Castellanos",
         at: 0.75,
         text: "The send goes out under %<value>s, their account executive.",
         probe: "Under whose name does the send go out? Reply with the name only."
    change :deadline, "October 9",
           at: 0.8,
           text: "Their kickoff moved up: the gift must land by %<value>s."
    fact :cc, "revops@shopify.example",
         at: 0.85,
         text: "Copy %<value>s on the confirmation.",
         probe: "Which address gets copied on the confirmation? Reply with the address only."
  end

  segment do
    fact :second_contact, "Ines Duarte",
         at: 0.1, carrier: :tool,
         text: '{"contact":{"name":"%<value>s","title":"Director of Demand Gen"}}',
         probe: "Who is the second contact we added? Reply with the full name only."
    change :item, "espresso set",
           at: 0.4, carrier: :assistant,
           text: "Switching the gift to the %<value>s: the notebook bundle is out of stock."
    fact :note_limit, "80",
         at: 0.7,
         text: "Keep the note under %<value>s words.",
         probe: "What is the word limit for the note? Reply with the number only."
  end

  continuation prompt: "We are cleared to send. Call draft_send once with the recipient's name " \
                       "and email, the item, the budget per gift, and the delivery deadline we " \
                       "agreed.",
               tool: "draft_send",
               description: "Drafts the gift send with the agreed details.",
               schema: lambda {
                 string :recipient_name, "Recipient full name", required: true
                 string :email, "Recipient email", required: true
                 string :item, "Gift to send", required: true
                 string :budget_usd, "Budget per gift", required: true
                 string :deadline, "Delivery deadline", required: true
               },
               expected: lambda { |latest|
                 { "recipient_name" => latest[:contact], "email" => latest[:email],
                   "item" => latest[:item], "budget_usd" => latest[:budget],
                   "deadline" => latest[:deadline] }
               }
end
