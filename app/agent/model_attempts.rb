# The attempts of one model call, made here rather than by the SDK (threat
# model SR-20; design §10, M3-4). The SDK fixes a call's timeout when the call
# begins and gives each of its retries that same timeout (anthropic 2.8,
# BaseClient#send_request: the requester's deadline is the attempt's start
# plus the call's timeout), so a retry that started before a turn's sixty
# seconds could run near sixty more: SR-20's exception until M3 (review
# finding C2's sister of pull request #9). Here the SDK makes one attempt per
# call (max_retries 0), and each attempt takes only what is left of the
# turn's edge (TurnEdge), at most the caller's own timeout.
#
# A failed attempt is tried again as the SDK would try it (BaseClient.
# should_retry? and #retry_delay): a connection's failure or timeout, and a
# 408, 409, 429 or 5xx unless the API answers x-should-retry false; after the
# wait the response asks for (RetryAfter), else the SDK's backoff from the
# client's own delays, with its jitter. A retry whose wait is longer than the
# caller allows, or than what is left of the edge, is not made, and the
# attempt's error is raised (review findings C2 of pull request #9 and C1 of
# #54).
class ModelAttempts
  # The statuses the SDK retries below 500.
  RETRY_STATUSES = [ 408, 409, 429 ].freeze

  # edge is the turn's, or nil for a call with none (the eval runner's
  # check); retries the attempts after the first; timeout the caller's own
  # bound of each attempt; max_wait the longest wait before a retry.
  def initialize(client:, edge:, retries:, timeout: nil, max_wait: nil, sleeper: nil)
    @client = client
    @edge = edge
    @retries = retries
    @timeout = timeout
    @max_wait = max_wait
    @sleeper = sleeper || Kernel.method(:sleep)
  end

  # An attempt that timed out once its request was on its way: the provider
  # runs such a call to its end and bills it whole (design §10, question 20).
  # One whose connection never opened sent nothing, and a host whose network
  # is down meets that on every turn.
  def self.abandoned?(error)
    error.is_a?(Anthropic::Errors::APITimeoutError) && !error.cause.is_a?(Net::OpenTimeout)
  end

  # Yields each attempt's request options, its timeout and the SDK's retries
  # off, and returns what the block returns. Raises AgentRunner's
  # DeadlineExceeded when nothing is left of the edge before an attempt, and
  # the last attempt's error when no retry follows it.
  def call
    tries = 0
    loop do
      left = remaining
      raise AgentRunner::DeadlineExceeded, "the turn's edge is reached" unless left.positive?

      begin
        return yield({ timeout: [ @timeout, left ].compact.min, max_retries: 0 })
      rescue Anthropic::Errors::APIError => e
        wait = (wait_before_retry(e, tries) if tries < @retries)
        raise unless wait && wait < remaining

        tries += 1
        @sleeper.call(wait)
      end
    end
  end

  private

  def remaining = @edge ? @edge.remaining : Float::INFINITY

  def wait_before_retry(error, tries)
    return unless retryable?(error)

    wait = RetryAfter.seconds(error.headers || {}) if error.is_a?(Anthropic::Errors::APIStatusError)
    wait = backoff(tries) unless wait&.positive?
    wait unless @max_wait && wait > @max_wait
  end

  def retryable?(error)
    return true if error.is_a?(Anthropic::Errors::APIConnectionError)
    return false unless error.is_a?(Anthropic::Errors::APIStatusError)

    should = error.headers&.[]("x-should-retry")
    return should == "true" if %w[true false].include?(should)

    RETRY_STATUSES.include?(error.status) || error.status.to_i >= 500
  end

  def backoff(tries)
    (@client.initial_retry_delay * (2**tries)).clamp(0, @client.max_retry_delay) * (1 - (0.25 * rand))
  end
end
