# The wait a failed model call's response asks for before a retry, read as
# the Anthropic SDK reads it (anthropic 2.8, base_client#retry_delay):
# retry-after-ms, then retry-after in seconds or as an HTTP date; nil when it
# asks for none. The SDK waits that long however long it is, so each caller
# bounds it by turning the retry off (refused): AgentRunner by what is left
# of the turn's wall clock (review finding C2 of pull request #9), Guardrail
# by its own small bound (review finding C1 of pull request #54).
module RetryAfter
  module_function

  def seconds(headers)
    if (milliseconds = Float(headers["retry-after-ms"], exception: false))
      return milliseconds / 1000
    end

    after = headers["retry-after"] or return
    Float(after, exception: false) || (Time.httpdate(after) - Time.now)
  rescue ArgumentError
    nil
  end

  # The response as the SDK will read it, its retry turned off: the SDK
  # raises the attempt's error at once. It reads x-should-retry first.
  def refused(response)
    Anthropic::APIResponse.new(status: response.status, headers: response.headers.merge("x-should-retry" => "false"),
                               body: response.body, raw: response.raw, request: response.request)
  end
end
