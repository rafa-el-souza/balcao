require "digest"
require_relative "case_set"
require_relative "checks"
require_relative "judge"

# The recorded fast subset (evals/README.md, Running): the cases marked
# `fast: true` of a delivered milestone, each recorded once on the normal
# model with the dev/eval key (bin/evals --record --fast) and replayed in CI
# with no key and no network (bin/evals --recorded): through the app's own
# pipeline, against the fake model (FakeModel), which answers each model call
# with the response the API gave at the recording, in order. FR-20's check
# shares the client (Guardrail.default_client), so its calls are recorded in
# their place among the attendant's (#54's notes; M2's first close).
#
# A recording speaks for what the model read: the system prompt, the tools,
# the history and FR-20's check (PromptDigest, as ADR-0003's gate names
# them), the normal route's model and effort, the case's messages, an
# opener's text among them (config/openers.yml), and its seed's catalogue,
# which the tools' results carry. A change to
# any of them makes it stale, and the replay fails the case, naming what
# changed, until the slice that made the change records it again. The
# expectations are not recorded: the replay grades the recorded replies
# against the cases as they stand.
#
# A tool call names a product by its id, which the catalogue's seed draws
# anew in each attempt, so a recording keeps every product id its answers
# name with the product's sku, and the replay serves each answer with the id
# the same product has in the replay's catalogue (Replayed).
#
# Beside each answer the recording keeps a digest of the request the app sent
# for it (Recording.request), and the replay compares each request it answers
# with it: what the model reads beyond the five digests (a store sheet's
# topic, which get_store_info carries; the tools' own logic; the request's
# parameters) reaches the model in those requests, and a change fails the
# case, naming the request (the review of #66, C1). What differs from run to
# run by design is set aside first (VOLATILE).
#
# The rubric's verdict is recorded too, with a digest of what the judge read
# (its prompt and route, the rubric, the reply in its authors' parts): the
# replay calls no judge, and takes the recorded verdict only when the judge
# would read the same; otherwise the case fails as stale.
module Evals
  class Recording
    DIR = Rails.root.join("evals/recordings")
    # The headers of an API answer that steer a retry (ModelAttempts,
    # RetryAfter), kept so a recorded 429 or 529 is replayed as it came.
    HEADERS = %w[retry-after retry-after-ms x-should-retry].freeze
    DIGESTS = %w[prompt tools history guardrail case].freeze
    UUID = /\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/
    # What differs from run to run by design in a request the app sends, set
    # aside before its digest: a product's id (drawn anew by every attempt's
    # seed), the time line the history writes for each visitor message
    # (AgentRunner::History::SENT), a timestamp (a reservation's
    # pickup_until), and a reservation's code in a tool's result, drawn at
    # random. Inside a tool's result, which is JSON in a string, the quotes
    # come escaped.
    VOLATILE = [
      [ UUID, "<uuid>" ],
      [ /\b(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday), \d{4}-\d{2}-\d{2} \d{2}:\d{2}\b/, "<sent>" ],
      [ /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})/, "<time>" ],
      [ /(\\*"code\\*":\s*\\*")[^"\\]+/, "\\1<code>" ]
    ].freeze

    attr_reader :path, :data

    def self.path(kase, dir = DIR) = Pathname(dir).join("#{kase.id}.json")

    # What a recording made now would speak for. The case's own part is its
    # messages and its seed's catalogue, whose names, prices and stock the
    # tools' results carry to the model (evals/seeds overlays the default
    # one, as the pipeline seeds it).
    def self.digests(kase)
      { "prompt" => PromptDigest.prompt, "tools" => PromptDigest.tools, "history" => PromptDigest.history,
        "guardrail" => PromptDigest.guardrail, "case" => PromptDigest.digest([ kase.seed, catalogue(kase.seed), kase.messages ]) }
    end

    def self.catalogue(seed)
      CatalogueSeed.entries(overlay: (CaseSet::SEEDS.join("#{seed}.yml") unless seed == "default"))
    end

    # A request the app sent, by digest, with VOLATILE set aside.
    def self.request(body)
      text = JSON.generate(body)
      VOLATILE.each { |pattern, mark| text = text.gsub(pattern, mark) }
      Digest::SHA256.hexdigest(text)[0, 16]
    end

    def self.route
      route = ModelPolicy.route("normal")
      { "model" => route.model, "effort" => route.effort.to_s }
    end

    # What the judge reads, by digest: the request a grade sends, whole (its
    # prompt and route, the rubric and the reply's parts as it renders them,
    # the answer's schema, the token cap), the client's timeout aside, which
    # the API never reads (the review of #66, C2).
    def self.reads(rubric, parts)
      request = Evals::Judge.new(client: nil).request(rubric:, parts:).except(:request_options)
      output = request.fetch(:output_config)
      Digest::SHA256.hexdigest(JSON.generate(request.merge(output_config: output.merge(format: output.fetch(:format).to_json_schema))))
    end

    def self.load(kase, dir = DIR)
      path = path(kase, dir)
      new(path, JSON.parse(path.read)) if path.exist?
    end

    # Writes the recording of a case's passing attempt through a temporary
    # file renamed, so a run that breaks while writing leaves the old one.
    def self.write(kase, dir:, responses:, verdict:, parts:, commit:, at:, products: {})
      data = { "case" => kase.id, "recorded_at" => at.utc.iso8601, "commit" => commit, "route" => route, "digests" => digests(kase),
               "responses" => responses }
      data["products"] = products.sort.to_h if products.any?
      if kase.rubric
        data["verdict"] = { "reads" => reads(kase.rubric, parts), "pass" => verdict.pass, "reason" => verdict.reason, "model" => verdict.model }
      end
      FileUtils.mkdir_p(dir)
      File.atomic_write(path(kase, dir).to_s) { |file| file.write("#{JSON.pretty_generate(data)}\n") }
    end

    def initialize(path, data)
      @path = path
      @data = data
    end

    # What changed since the recording, by name; empty when it speaks for
    # what the model would read now.
    def stale(kase)
      changed = self.class.digests(kase).reject { |name, digest| data.dig("digests", name) == digest }.keys
      changed << "route" unless data["route"] == self.class.route
      changed << "case id" unless data["case"] == kase.id
      changed
    end

    def responses = data.fetch("responses")
    def recorded_at = Time.iso8601(data.fetch("recorded_at"))
    def verdict = data["verdict"]
    def products = data.fetch("products", {})

    # The SDK's middleware that keeps each attempt's answer as the API gave
    # it, in the shape FakeModel replays: the status, the body (as text, with
    # its type, when it is not JSON) and the headers that steer a retry, or a
    # timeout, true once the request was on
    # its way and "open" when it never was (ModelAttempts.abandoned?), with
    # the digest of the request the answer was for (Recording.request), and
    # the sku of every product an answer names by its id, read in the
    # attempt's own catalogue. An answer it cannot keep (a connection's
    # failure, a body that is not JSON) marks the attempt unrecordable, and
    # nothing is written for it.
    class Recorder
      include Anthropic::Middleware

      attr_reader :responses, :products, :broken

      def initialize
        @responses = []
        @products = {}
        @broken = nil
      end

      def call(request, nxt)
        sent = Recording.request(request.body)
        response = nxt.call(request)
        response.buffer!
        body = response.body.join
        parsed = parse(body)
        kept = HEADERS.filter_map { |name| [ name, response.headers[name] ] if response.headers[name] }.to_h
        # An answer whose body is not JSON (an edge's HTML 503) goes on to the
        # SDK as it came, which retries it as in production, and is kept as
        # text with its type, which FakeModel serves as it came (the review
        # of #66, C4 and V3).
        unless parsed
          kept["content-type"] = response.headers["content-type"] if response.headers["content-type"]
          @responses << { "request" => sent, "status" => response.status, "headers" => kept.presence, "body_text" => body }.compact
          return response
        end

        @responses << { "request" => sent, "status" => response.status, "headers" => kept.presence, "body" => parsed }.compact
        @products.merge!(Product.where(id: body.scan(UUID).uniq).pluck(:id, :sku).to_h)
        response
      rescue Anthropic::Errors::APITimeoutError => e
        @responses << { "request" => sent, "timeout" => e.cause.is_a?(Net::ReadTimeout) ? true : "open" }
        raise
      rescue StandardError => e
        @broken ||= "#{e.class}: #{e.message}"
        raise
      end

      private

      def parse(body)
        JSON.parse(body)
      rescue JSON::ParserError
        nil
      end
    end

    # The pipeline of a recording run: each attempt runs live through the
    # app's pipeline with a client of its own, whose recorder keeps every
    # model call of the attempt, the check's among them. The judge keeps its
    # own client, so its calls are never recorded.
    class Pipeline
      Kept = Data.define(:responses, :products, :broken)

      # client: builds an SDK client with the recorder as its middleware.
      def initialize(inner, client:)
        @inner = inner
        @client = client
        @kept = {}.compare_by_identity
      end

      def mode = @inner.mode

      def run(kase)
        recorder = Recorder.new
        run = AgentRunner.with_client(@client.call(recorder)) { @inner.run(kase) }
        @kept[run] = Kept.new(responses: recorder.responses, products: recorder.products, broken: recorder.broken)
        run
      end

      # The recording of the case's first passing attempt, written; or why
      # none was.
      def write(result, dir:, commit:)
        attempt = result.attempts.find { |candidate| candidate.status == :pass }
        return "not recorded: no attempt passed" unless attempt

        kept = @kept[attempt.run]
        return "not recorded: #{kept.broken}" if kept.broken

        Recording.write(result.kase, dir:, responses: kept.responses, verdict: attempt.verdict, parts: attempt.run.observation.parts,
                                     commit:, at: attempt.started_at, products: kept.products)
        nil
      end
    end

    # The fake model of a replay: each recorded answer, served with every
    # product id the recording names turned into the id the same product,
    # by its sku, has in the replay's catalogue, read when its request comes,
    # after the attempt's seed. It notes the first request that differs from
    # the one the answer was recorded for (Recording.request), by its
    # position, and serves the answer all the same, so the run ends and the
    # replay names it.
    class Replayed < FakeModel
      # The first request that differed, as "request N", or nil.
      attr_reader :differed

      def initialize(recording)
        super(recording.responses)
        @products = recording.products
        @differed = nil
      end

      def call(request, nxt)
        if @responses.any?
          recorded = @responses[0][:request]
          @differed ||= "request #{@requests.size + 1}" if recorded && recorded != Recording.request(request.body)
          @responses[0] = current(@responses[0]) if @products.any?
        end
        super
      end

      private

      def current(response)
        now = Product.where(sku: @products.values).pluck(:sku, :id).to_h
        JSON.parse(JSON.generate(response).gsub(UUID) { |id| (sku = @products[id]) ? now.fetch(sku) : id }, symbolize_names: true)
      end
    end

    # The judge of a replay: the recorded verdict, when the judge would read
    # what it read at the recording; else an error that fails the case.
    class Verdicts
      class Stale < StandardError; end

      def initialize(recordings)
        @verdicts = recordings.filter_map(&:verdict).index_by { |verdict| verdict["reads"] }
      end

      def model = @verdicts.values.first&.fetch("model")

      def grade(rubric:, parts:)
        recorded = @verdicts[Recording.reads(rubric, parts)] or
          raise Stale, "the judge would read another reply or rubric than the recording's verdict did"

        Evals::Judge::Verdict.new(pass: recorded.fetch("pass"), reason: recorded["reason"], model: recorded["model"],
                                  usage: { input_tokens: 0, output_tokens: 0, cache_read_tokens: 0, cache_write_tokens: 0 })
      end
    end
  end
end
