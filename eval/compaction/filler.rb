# frozen_string_literal: true

module CompactionEval
  # The turns between the facts: a few shapes per scenario, rotated so the
  # summarizer faces the variety a real session has, and every seventh turn
  # a tool call that fails the way real ones do. Everything is generated from
  # the seeded Random, so a seed builds the same session twice.
  module Filler
    FAILURE_EVERY = 7
    FAILURES = ["error: connection reset by peer", "error: request timed out after 30s",
                "error: 503 Service Unavailable from upstream"].freeze

    module_function

    def shape(index, shapes) = shapes.fetch(index % shapes.length)

    def fails?(index) = (index % FAILURE_EVERY) == FAILURE_EVERY - 1

    # Swaps the result for an error and the closing line for a retry note. The
    # builder applies it only to turns that carry no tool-borne fact, so a
    # fact meant to sit inside a long result never lands in a short error.
    def fail(shape, rng)
      failure = FAILURES.fetch(rng.rand(FAILURES.length))
      shape.merge(log: ->(_chars) { failure },
                  done: "That call failed (#{failure}). I will retry it on the next pass " \
                        "rather than guess at the result; nothing about the plan changes.")
    end

    def worker_log(rng)
      lambda do |chars|
        Noise.lines(rng, chars) do |index, random|
          format("%<at>s worker-%<worker>d job=%<job>d status=%<status>s latency=%<ms>dms " \
                 "shard=%<shard>d",
                 at: Noise.stamp(random), worker: random.rand(12),
                 job: 400_000 + random.rand(90_000),
                 status: %w[ok ok ok ok retry skipped][random.rand(6)],
                 ms: 20 + random.rand(900), shard: index % 8)
        end
      end
    end

    def sql_counts(rng)
      lambda do |chars|
        Noise.lines(rng, chars) do |index, random|
          status = %w[staged staged staged balanced exported held][index % 6]
          format("%<status>-10s | %<count>7d | %<at>s",
                 status: status, count: random.rand(20_000), at: Noise.stamp(random))
        end
      end
    end

    def grep_hits(rng)
      lambda do |chars|
        Noise.lines(rng, chars) do |_index, random|
          format("%<at>s reconcile shop_id=%<shop>d period=2026-Q3 status=unique",
                 at: Noise.stamp(random), shop: 10_000 + random.rand(90_000))
        end
      end
    end

    def replica_lag(rng)
      lambda do |chars|
        Noise.lines(rng, chars) do |_index, random|
          format("%<at>s lag=%<lag>0.3fs wal_bytes=%<wal>d",
                 at: Noise.stamp(random), lag: random.rand * 0.9, wal: random.rand(5_000_000))
        end
      end
    end

    def request_log(rng)
      lambda do |chars|
        Noise.lines(rng, chars) do |_index, random|
          format("%<at>s %<level>s %<route>s status=%<status>d duration=%<ms>dms " \
                 "request_id=req_%<request>08x",
                 at: Noise.stamp(random), level: %w[INFO INFO INFO WARN][random.rand(4)],
                 route: ["GET /v1/addresses/validate", "POST /v1/addresses/normalize",
                         "GET /healthz"][random.rand(3)],
                 status: [200, 200, 200, 422, 500][random.rand(5)], ms: 8 + random.rand(400),
                 request: random.rand(2**32))
        end
      end
    end

    def metric_series(rng)
      lambda do |chars|
        Noise.lines(rng, chars) do |_index, random|
          format("%<at>s address_validation.errors rate=%<rate>0.4f req/s errors=%<errors>d",
                 at: Noise.stamp(random), rate: random.rand * 0.05, errors: random.rand(9))
        end
      end
    end

    def rspec_output(rng)
      lambda do |chars|
        Noise.lines(rng, chars) do |index, random|
          format("AddressType %<what>s (%<ms>dms) %<mark>s",
                 what: ["normalizes street lines", "keeps unit numbers", "handles rural routes",
                        "rejects empty postal codes"][index % 4],
                 ms: 1 + random.rand(40), mark: index % 9 == 8 ? "FAILED" : "ok")
        end
      end
    end

    def health_checks(rng)
      lambda do |chars|
        Noise.lines(rng, chars) do |index, random|
          format("pod-%<pod>s /healthz %<code>d %<ms>dms", pod: %w[a b c][index % 3],
                                                           code: 200, ms: 2 + random.rand(30))
        end
      end
    end

    def activity_json(rng)
      lambda do |chars|
        Noise.lines(rng, chars) do |index, random|
          format('{"id":"act_%<id>06d","at":"%<at>s","type":"%<type>s","actor":"%<actor>s",' \
                 '"summary":"%<summary>s"}',
                 id: 100_000 + index + random.rand(500), at: Noise.stamp(random),
                 type: %w[email_open page_view webinar_signup meeting][random.rand(4)],
                 actor: %w[analyst ops-lead sdr unknown][random.rand(4)],
                 summary: ["viewed pricing page", "opened Q3 newsletter",
                           "joined roadmap webinar", "no-show on intro call"][random.rand(4)])
        end
      end
    end

    def tickets_json(rng)
      lambda do |chars|
        Noise.lines(rng, chars) do |index, random|
          format('{"ticket":"T-%<id>05d","opened":"%<at>s","subject":"%<subject>s",' \
                 '"priority":"%<priority>s"}',
                 id: 40_000 + index, at: Noise.stamp(random),
                 subject: ["theme section not rendering", "app install question",
                           "shipping zone setup", "invoice copy request"][random.rand(4)],
                 priority: %w[low normal normal high][random.rand(4)])
        end
      end
    end

    def news_json(rng)
      lambda do |chars|
        Noise.lines(rng, chars) do |_index, random|
          format('{"published":"%<at>s","headline":"%<headline>s","source":"%<source>s"}',
                 at: Noise.stamp(random),
                 headline: ["Launches new wool runner colourway", "Publishes sustainability report",
                            "Opens pop-up store downtown",
                            "Names new head of retail"][random.rand(4)],
                 source: %w[retail-wire trade-daily local-news][random.rand(3)])
        end
      end
    end

    def touches_json(rng)
      lambda do |chars|
        Noise.lines(rng, chars) do |_index, random|
          format('{"at":"%<at>s","channel":"%<channel>s","owner":"account team",' \
                 '"note":"%<note>s"}',
                 at: Noise.stamp(random), channel: %w[email call linkedin][random.rand(3)],
                 note: ["quarterly check-in", "renewal timing", "shared roadmap deck",
                        "intro to solutions engineer"][random.rand(4)])
        end
      end
    end
  end
end
