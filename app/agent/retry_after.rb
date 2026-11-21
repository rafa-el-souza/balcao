# The wait a failed model call's response asks for before a retry, read as
# the Anthropic SDK reads it (anthropic 2.8, base_client#retry_delay):
# retry-after-ms, then retry-after in seconds or as an HTTP date; nil when it
# asks for none. The SDK waits that long however long it is; ModelAttempts,
# which makes the retries itself, bounds it: by what is left of the turn's
# edge (review finding C2 of pull request #9) and, for FR-20's check, by its
# own small bound (review finding C1 of pull request #54).
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
end
