# Runs one turn through the model (design §6.3, §6.4): the conversation's last
# thirty turns, the cached system prompt, the turn's tools and the budget
# mode's model, through the official SDK's tool runner, which calls the model,
# runs the tools it asks for and sends their results back until the model
# answers. AgentRunner adds what the turn needs around that loop:
#
# - the limits of threat model SR-20: at most six tool calls, 1,500 output
#   tokens per call and sixty seconds of wall clock, past which the turn ends
#   without text and the caller sends the fallback (NFR-03);
# - an outcome for every way a call can end, so a refusal never reaches the
#   visitor as text (SR-19) and a model error is a result, not an exception;
# - the usage of every model call, from usage.iterations when a fallback model
#   served it, for the budget (FR-14);
# - the reply's language, read from the tag the prompt asks for (FR-02);
# - an event for each step as it happens, for the trace (FR-12, ADR-0010).
#
# It stores nothing: the caller records the reply, the usage and the trace.
class AgentRunner
  MAX_TOOL_CALLS = 6
  MAX_TOKENS = 1_500
  WALL_CLOCK = 60
  # The SDK's own retries of a 408, 409, 429, 5xx or timeout: three attempts
  # per model call, the three of NFR-03's scenario.
  MAX_RETRIES = 2
  MONOTONIC = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

  LANGUAGE_TAG = /\A\s*\[(pt|en|es)\][ \t]*/
  LANGUAGES = { "pt" => "pt-BR", "en" => "en", "es" => "es" }.freeze

  # What one model call used; a call a fallback model served has one per attempt.
  Usage = Data.define(:model, :input_tokens, :output_tokens, :cache_creation_tokens, :cached_tokens)
  # Events, in the order they happen; ModelCall and ToolCall are also in the result.
  ModelStarted = Data.define(:model, :effort)
  ModelCall = Data.define(:model, :effort, :stop_reason, :usage, :latency_ms, :error)
  ToolCall = Data.define(:name, :input, :output, :is_error, :latency_ms)

  # outcome: :replied (text and language set), :refused, :incomplete (cut off
  # or empty), :tool_limit, :deadline or :model_error (error set).
  Result = Data.define(:outcome, :text, :language, :model_calls, :tool_calls, :error)

  class DeadlineExceeded < StandardError; end

  def self.default_client
    @default_client ||= begin
      api_key = ENV["ANTHROPIC_API_KEY"].presence or raise KeyError, "ANTHROPIC_API_KEY is blank; the real model needs its key (design §8)"
      Anthropic::Client.new(api_key:, max_retries: MAX_RETRIES)
    end
  end

  def initialize(client: nil, tools: Tools::ALL, clock: MONOTONIC, prompt: SystemPrompt.current)
    @client = client || self.class.default_client
    @tools = tools
    @clock = clock
    @prompt = prompt
  end

  # Runs the turn in the budget mode's route and yields each event to the
  # block, if one is given. Raises ArgumentError for a mode that calls no model.
  def run(turn, mode: "normal", &on_event)
    Run.new(client: @client, turn:, route: ModelPolicy.route(mode), tools: @tools, clock: @clock, prompt: @prompt,
            on_event:).call
  end

  # One turn's state. Through Watch it sees each attempt of each model call:
  # it records the call when the answer arrives, before the SDK's runner runs
  # the tools it asks for, and a retry the SDK makes after the wall clock is
  # gone never starts.
  class Run
    def initialize(client:, turn:, route:, tools:, clock:, prompt:, on_event:)
      @client = client
      @turn = turn
      @route = route
      @clock = clock
      @prompt = prompt
      @on_event = on_event
      @deadline = clock.call + WALL_CLOCK
      @model_calls = []
      @tool_calls = []
      @tool_uses = 0
      @tool_runs = 0
      @messages = []
      @tools = tools.map { |tool| tool.new(turn:, on_call: method(:tool_called), gate: method(:permit_tool_call)) }
    end

    # One step of the SDK's runner is one model call and the tool calls it
    # asks for; each step's request may take only what is left of the turn's
    # wall clock, measured after the previous step's tools have run.
    def call
      runner = @client.beta.messages.tool_runner(params)
      last = nil
      until runner.finished? || @tool_uses > MAX_TOOL_CALLS
        check_deadline
        runner.params.update(request_options:)
        start_model_call
        message = runner.next_message or break
        last = message
        @messages << message
        @tool_uses += message.content.count { |block| block.type == :tool_use }
      end
      result_of(last)
    rescue DeadlineExceeded => e
      model_failed(e) if @started_at
      result(:deadline)
    rescue Anthropic::Errors::APIError => e
      model_failed(e)
      result(:model_error, error: e)
    end

    def check_deadline
      raise DeadlineExceeded, "the turn's #{WALL_CLOCK} s are spent" if remaining <= 0
    end

    # The SDK waits as long as a failed attempt's retry-after asks before it
    # retries, however long; a wait that outlasts what is left of the turn
    # is not made, and the SDK raises the attempt's error at once (review
    # finding C2 of pull request #9, SR-20). It reads x-should-retry first.
    def bound_retry(response)
      wait = requested_wait(response.headers)
      return response unless wait && wait >= remaining

      Anthropic::APIResponse.new(status: response.status, headers: response.headers.merge("x-should-retry" => "false"),
                                 body: response.body, raw: response.raw, request: response.request)
    end

    # The model's answer, as it arrives and before the SDK runs its tools.
    def model_answered(message)
      record(ModelCall.new(model: message.model.to_s, effort: @route.effort, stop_reason: message.stop_reason.to_s,
                           usage: usage_of(message), latency_ms:, error: nil))
    end

    private

    def params
      {
        model: @route.model,
        max_tokens: MAX_TOKENS,
        # The tools render before the system prompt, so this one breakpoint
        # caches both; the top-level one caches the conversation so far.
        system_: [ { type: "text", text: @prompt, cache_control: { type: "ephemeral" } } ],
        cache_control: { type: "ephemeral" },
        messages: History.messages(@turn),
        output_config: { effort: @route.effort },
        # The history is rebuilt from the database every turn, so the turn's
        # few requests go as plain Messages API calls, with no message thread.
        thread: false,
        max_iterations: MAX_TOOL_CALLS + 1,
        request_options:
      }.merge(tools_param, fallbacks_param)
    end

    def tools_param = @tools.any? ? { tools: @tools } : {}

    def fallbacks_param
      return {} unless @route.fallbacks

      { fallbacks: @route.fallbacks, betas: [ ModelPolicy::FALLBACK_BETA ] }
    end

    def request_options = { middleware: [ Watch.new(self) ], timeout: remaining }

    def start_model_call
      @started_at = @clock.call
      emit(ModelStarted.new(model: @route.model, effort: @route.effort))
    end

    # The SDK's runner calls a tool only through this gate, so a seventh call
    # never runs, even inside a batch of parallel calls (SR-20).
    def permit_tool_call
      @tool_runs += 1
      raise AgentTool::Error, "the turn's limit of #{MAX_TOOL_CALLS} tool calls is reached" if @tool_runs > MAX_TOOL_CALLS
    end

    def remaining = @deadline - @clock.call

    # The wait a response asks for, in seconds, read as the SDK reads it:
    # retry-after-ms, then retry-after in seconds or as an HTTP date.
    def requested_wait(headers)
      if (milliseconds = Float(headers["retry-after-ms"], exception: false))
        return milliseconds / 1000
      end

      after = headers["retry-after"] or return
      Float(after, exception: false) || (Time.httpdate(after) - Time.now)
    rescue ArgumentError
      nil
    end

    def result_of(message)
      case message&.stop_reason
      when :end_turn, :stop_sequence then reply
      when :refusal then result(:refused)
      when :tool_use then result(:tool_limit)
      else result(:incomplete)
      end
    end

    # The reply is the text of every step of the turn, in order: what the
    # model writes before a tool call is shown too, and may carry the tag or
    # the declined clinical part of a mixed question (review finding C1 of
    # pull request #9). Each block's leading tag is removed; the first names
    # the language.
    def reply
      blocks = @messages.flat_map { |message| message.content.select { |block| block.type == :text }.map(&:text) }
      tag = blocks.filter_map { |block| block[LANGUAGE_TAG, 1] }.first
      text = blocks.map { |block| block.sub(LANGUAGE_TAG, "").strip }.reject(&:empty?).join("\n\n")
      return result(:incomplete) if text.empty?

      result(:replied, text:, language: LANGUAGES[tag])
    end

    def result(outcome, text: nil, language: nil, error: nil)
      Result.new(outcome:, text:, language:, model_calls: @model_calls, tool_calls: @tool_calls, error:)
    end

    def model_failed(error)
      record(ModelCall.new(model: @route.model, effort: @route.effort, stop_reason: nil, usage: [], latency_ms:,
                           error: error.class.name))
    end

    def record(call)
      @started_at = nil
      @model_calls << call
      emit(call)
    end

    def latency_ms = @started_at && ((@clock.call - @started_at) * 1000).round

    # usage.iterations holds every attempt when the API retried on a fallback
    # model, each at its own model's price; the top-level usage is then only
    # the attempt that answered.
    def usage_of(message)
      usage = message.usage
      attempts = Array(usage.iterations).select { |entry| %i[message fallback_message].include?(entry.type) }
      return [ usage_from(usage, message.model) ] if attempts.empty?

      attempts.map { |attempt| usage_from(attempt, attempt.model || @route.model) }
    end

    def usage_from(usage, model)
      Usage.new(model: model.to_s, input_tokens: usage.input_tokens, output_tokens: usage.output_tokens,
                cache_creation_tokens: usage.cache_creation_input_tokens.to_i,
                cached_tokens: usage.cache_read_input_tokens.to_i)
    end

    def tool_called(call)
      @tool_calls << call
      emit(call)
    end

    def emit(event) = @on_event&.call(event)
  end

  # The request middleware around every attempt of a model call, the SDK's
  # retries included: the wall clock is checked before it, an answer is
  # recorded as it arrives, and a failed one's retry is bounded by the clock
  # (the SDK raises its error later).
  Watch = Struct.new(:run) do
    def call(request, nxt)
      run.check_deadline
      response = nxt.call(request)
      return run.bound_retry(response) if response.status >= 300

      run.model_answered(response.parse)
      response
    end
  end
end
